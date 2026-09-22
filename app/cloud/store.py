"""Storage-backed immutable submissions, ETag ownership and bounded admission."""

import hashlib
import json
import re
import time
from contextlib import contextmanager
from functools import lru_cache

from azure.core import MatchConditions
from azure.core.exceptions import (
    AzureError,
    ResourceExistsError,
    ResourceModifiedError,
    ResourceNotFoundError,
)
from azure.data.tables import TableClient, UpdateMode
from azure.storage.blob import BlobServiceClient, ContentSettings
from azure.storage.queue import QueueClient
from loguru import logger

from app.cloud.models import MAX_FILE_BYTES, MAX_TASK_BYTES, CloudRequest
from app.cloud.settings import allowed_users, identifier, provider_snapshot, required
from app.services.azure_auth import credential

TERMINAL = frozenset(("succeeded", "failed", "needs_review"))
ACTIVE = frozenset(("pending_dispatch", "queued", "running"))


class CapacityError(ValueError):
    pass


class OwnershipLost(RuntimeError):
    pass


def json_bytes(value) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Store:
    def __init__(self):
        account = required("MPT_STORAGE_ACCOUNT")
        if not re.fullmatch(r"[a-z0-9]{3,24}", account):
            raise ValueError("Invalid storage account name")
        auth = credential()
        self.blobs = BlobServiceClient(
            f"https://{account}.blob.core.windows.net", credential=auth
        ).get_container_client("tasks")
        self.table = TableClient(
            f"https://{account}.table.core.windows.net", "tasks", credential=auth
        )
        self.queue = QueueClient(
            f"https://{account}.queue.core.windows.net", "tasks", credential=auth
        )
        self.poison = QueueClient(
            f"https://{account}.queue.core.windows.net", "poison", credential=auth
        )

    def put(
        self, key, data, *, overwrite=False, content_type="application/octet-stream"
    ):
        self.blobs.upload_blob(
            key,
            data,
            overwrite=overwrite,
            content_settings=ContentSettings(content_type=content_type),
        )

    def get_bytes(self, key, limit=MAX_FILE_BYTES):
        blob = self.blobs.get_blob_client(key)
        size = blob.get_blob_properties().size
        if size > limit:
            raise ValueError("Artifact exceeds the download size limit")
        return blob.download_blob(max_concurrency=1).readall()

    def get_json(self, key):
        return json.loads(self.get_bytes(key, limit=2 * 1024 * 1024))

    def optional_json(self, key):
        try:
            return self.get_json(key)
        except ResourceNotFoundError:
            return None

    def lease(self, name):
        blob = self.blobs.get_blob_client(f"locks/{name}")
        try:
            blob.upload_blob(b"", overwrite=False)
        except ResourceExistsError:
            pass
        return blob.acquire_lease(lease_duration=60)

    @contextmanager
    def admission(self):
        lease = self.lease("admission")
        try:
            yield
        finally:
            lease.release()

    def task(self, task_id):
        return self.table.get_entity("tasks", identifier(task_id))

    def update(self, entity, **values):
        updated = dict(entity)
        updated.update(values, updated=time.time())
        self.table.update_entity(
            updated,
            mode=UpdateMode.REPLACE,
            etag=entity.metadata["etag"],
            match_condition=MatchConditions.IfNotModified,
        )
        return self.task(entity["RowKey"])

    def owned_update(self, task_id, owner, **values):
        for _ in range(5):
            entity = self.task(task_id)
            if (
                entity.get("owner") != owner
                or entity.get("lease_until", 0) < time.time()
            ):
                raise OwnershipLost("Worker task lease was lost")
            try:
                return self.update(entity, **values)
            except ResourceModifiedError:
                continue
        raise OwnershipLost("Concurrent state updates prevented ownership verification")

    def tasks(self):
        return list(self.table.query_entities("PartitionKey eq 'tasks'"))

    def upload(self, owner, name, data):
        from pathlib import PurePath
        from uuid import uuid4

        owner = identifier(owner)
        if owner not in allowed_users():
            raise PermissionError("User is not authorized")
        suffix = PurePath(name.replace("\\", "/")).suffix.lower()
        if suffix not in (
            ".mp4",
            ".mov",
            ".webm",
            ".png",
            ".jpg",
            ".jpeg",
            ".wav",
            ".mp3",
            ".m4a",
        ):
            raise ValueError("Unsupported media extension")
        if not data or len(data) > MAX_FILE_BYTES:
            raise ValueError("Uploads must be nonempty and at most 100 MiB")
        key = f"uploads/{owner}/{uuid4()}{suffix}"
        self.put(key, data)
        return key

    def submit(self, task_id, owner, request: CloudRequest):
        task_id, owner = identifier(task_id), identifier(owner)
        if owner not in allowed_users():
            raise PermissionError("User is not authorized")
        payload = {
            "schema": 1,
            "owner": owner,
            "request": request.model_dump(mode="json"),
        }
        request_hash = digest(json_bytes(payload))
        manifest = {**payload, "providers": provider_snapshot()}
        # Serialized admission bounds queue size even across multiple API processes.
        with self.admission():
            try:
                existing = self.task(task_id)
            except ResourceNotFoundError:
                existing = None
            if existing:
                if (
                    existing["request_hash"] != request_hash
                    or existing["user"] != owner
                ):
                    raise ValueError(
                        "Idempotency key already belongs to a different request"
                    )
                return public_task(existing)
            active = sum(t["status"] in ACTIVE for t in self.tasks())
            if active >= 10:
                raise CapacityError("The cloud queue is full (10 active tasks)")
            if request.reuse_audio_task_id:
                preview_id = identifier(request.reuse_audio_task_id)
                preview = self.task(preview_id)
                if preview["user"] != owner or preview["status"] != "succeeded":
                    raise ValueError("Audio preview is not available for this user")
                previous = self.get_json(f"{preview_id}/manifest.json")
                previous_script = self.get_json(
                    f"{preview_id}/checkpoints/script/done.json"
                )["data"]["script"]
                if (
                    previous_script != request.params.video_script
                    or any(
                        previous["request"]["params"][key]
                        != getattr(request.params, key)
                        for key in ("voice_name", "voice_rate", "voice_volume")
                    )
                    or previous["providers"] != manifest["providers"]
                ):
                    raise ValueError(
                        "Audio preview narration, voice, rate or provider settings changed"
                    )
                self.get_json(f"{preview_id}/checkpoints/audio/done.json")
            total = 0
            for key in [
                *request.uploads,
                *([request.bgm_upload] if request.bgm_upload else []),
            ]:
                if not re.fullmatch(
                    rf"uploads/{owner}/[a-f0-9-]{{36}}\.[a-z0-9]+", key
                ):
                    raise ValueError("Uploads must belong to the submitting user")
                total += self.blobs.get_blob_client(key).get_blob_properties().size
            if total > MAX_TASK_BYTES:
                raise ValueError("Task inputs exceed 400 MiB")
            key = f"{task_id}/manifest.json"
            try:
                self.put(key, json_bytes(manifest), content_type="application/json")
            except ResourceExistsError:
                if self.get_json(key) != manifest:
                    raise ValueError("Conflicting immutable task manifest")
            now = time.time()
            self.table.create_entity(
                {
                    "PartitionKey": "tasks",
                    "RowKey": task_id,
                    "user": owner,
                    "request_hash": request_hash,
                    "status": "pending_dispatch",
                    "progress": 0,
                    "created": now,
                    "updated": now,
                    "attempts": 0,
                    "subject": request.params.video_subject,
                    "owner": "",
                    "lease_until": 0.0,
                    "stage": "dispatch",
                    "error": "",
                }
            )
        try:
            self.dispatch(self.task(task_id))
        except AzureError:
            logger.exception(
                "Task {} accepted; pending dispatch will be repaired by maintenance",
                task_id,
            )
        return public_task(self.task(task_id))

    def dispatch(self, entity):
        # If sending or the subsequent CAS fails, maintenance resends this same ID.
        self.queue.send_message(json.dumps({"schema": 1, "task_id": entity["RowKey"]}))
        if entity["status"] == "pending_dispatch":
            try:
                self.update(entity, status="queued")
            except ResourceModifiedError:
                pass  # A worker may already have atomically claimed the task.


def public_task(entity):
    status = entity["status"]
    return {
        "task_id": entity["RowKey"],
        "status": status,
        "state": 1 if status == "succeeded" else -1 if status in TERMINAL else 4,
        "progress": entity.get("progress", 0),
        "subject": entity.get("subject", ""),
        "stage": entity.get("stage", ""),
        "error": entity.get("error", ""),
        "created": entity["created"],
    }


@lru_cache(maxsize=1)
def store():
    return Store()
