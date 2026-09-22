"""Loopback-only FastAPI sidecar. Browser traffic never receives this address."""

import hmac
import mimetypes
from typing import Annotated
from uuid import uuid4

from azure.core.exceptions import AzureError, ResourceNotFoundError
from fastapi import Depends, FastAPI, Header, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, Response
from loguru import logger
from pydantic import ValidationError

from app.cloud.models import MAX_FILE_BYTES, CloudRequest
from app.cloud.settings import allowed_users, identifier, required
from app.cloud.store import CapacityError, public_task, store


def authorize(
    authorization: Annotated[str, Header()] = "",
    x_mpt_user: Annotated[str, Header()] = "",
):
    token = required("MPT_INTERNAL_API_TOKEN")
    if len(token) < 32 or not hmac.compare_digest(authorization, f"Bearer {token}"):
        raise HTTPException(401, "Invalid internal service credential")
    try:
        user = identifier(x_mpt_user)
    except ValueError as exc:
        raise HTTPException(403, "Invalid user identity") from exc
    if user not in allowed_users():
        raise HTTPException(403, "User is not authorized")
    return user


app = FastAPI(
    title="MoneyPrinterTurbo Azure internal API", docs_url=None, redoc_url=None
)
User = Annotated[str, Depends(authorize)]


class BodyLimit:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        limit = (
            MAX_FILE_BYTES + 1024 * 1024
            if scope["path"] == "/api/v1/uploads"
            else 64 * 1024
        )
        size = 0

        async def bounded_receive():
            nonlocal size
            message = await receive()
            size += len(message.get("body", b""))
            if size > limit:
                raise HTTPException(413, "Request body exceeds the cloud size limit")
            return message

        await self.app(scope, bounded_receive, send)


app.add_middleware(BodyLimit)


@app.exception_handler(AzureError)
def azure_error(request, exc):
    logger.error("Storage request failed: {}", type(exc).__name__)
    return JSONResponse(
        {"detail": "Azure Storage is unavailable; retry with the same task ID"},
        status_code=503,
    )


@app.exception_handler(ValueError)
def invalid_request(request, exc):
    return JSONResponse({"detail": str(exc)}, status_code=400)


@app.get("/health")
def health():
    return {"status": "ok"}


def own_task(task_id, user):
    try:
        task = store().task(task_id)
    except ResourceNotFoundError as exc:
        raise HTTPException(404, "Task not found") from exc
    if task["user"] != user:
        raise HTTPException(404, "Task not found")
    return task


@app.post("/api/v1/videos", status_code=202)
@app.post("/api/v1/audio", status_code=202)
@app.post("/api/v1/subtitle", status_code=202)
@app.post("/api/v1/script", status_code=202)
@app.post("/api/v1/terms", status_code=202)
@app.post("/api/v1/materials", status_code=202)
def submit(
    request: Request,
    body: CloudRequest,
    user: User,
    idempotency_key: Annotated[str, Header()] = "",
):
    stop = request.url.path.rsplit("/", 1)[-1]
    data = body.model_dump()
    if stop != "videos":
        data["stop_at"] = stop
    try:
        checked = CloudRequest.model_validate(data)
        result = store().submit(idempotency_key or str(uuid4()), user, checked)
    except CapacityError as exc:
        raise HTTPException(429, str(exc)) from exc
    except ValidationError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"status": 200, "data": result}


@app.get("/api/v1/tasks")
def tasks(user: User):
    rows = [t for t in store().tasks() if t["user"] == user]
    rows.sort(key=lambda t: t["created"], reverse=True)
    return {"data": {"tasks": [public_task(t) for t in rows[:100]], "total": len(rows)}}


@app.get("/api/v1/tasks/{task_id}")
def task(task_id: str, user: User):
    data = public_task(own_task(task_id, user))
    if data["status"] == "succeeded":
        result = store().get_json(f"{identifier(task_id)}/result.json")
        data["result"] = result["result"]
        data["artifacts"] = [
            {"name": name, "size": value["size"], "sha256": value["sha256"]}
            for name, value in result["artifacts"].items()
        ]
    return {"data": data}


@app.get("/api/v1/tasks/{task_id}/logs")
def logs(task_id: str, user: User):
    own_task(task_id, user)
    try:
        return Response(
            store().get_bytes(f"{identifier(task_id)}/worker.log", 256_000),
            media_type="text/plain",
        )
    except ResourceNotFoundError:
        return Response(
            "Logs are published when the worker finishes.", media_type="text/plain"
        )


@app.get("/api/v1/tasks/{task_id}/artifacts/{name:path}")
def artifact(task_id: str, name: str, user: User):
    entity = own_task(task_id, user)
    if entity["status"] != "succeeded":
        raise HTTPException(409, "Task artifacts have not been committed")
    result = store().get_json(f"{identifier(task_id)}/result.json")
    entry = result["artifacts"].get(name)
    if entry is None:
        raise HTTPException(404, "Artifact not found")
    from app.cloud.store import digest

    raw = store().get_bytes(entry["blob"])
    if digest(raw) != entry["sha256"]:
        raise HTTPException(503, "Artifact checksum mismatch")
    return Response(
        raw, media_type=mimetypes.guess_type(name)[0] or "application/octet-stream"
    )


@app.post("/api/v1/uploads")
async def upload(file: UploadFile, user: User):
    raw = await file.read(MAX_FILE_BYTES + 1)
    key = store().upload(user, file.filename or "", raw)
    return {"data": {"upload": key, "size": len(raw)}}
