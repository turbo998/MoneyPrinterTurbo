"""One job execution consumes one message; the platform scaler is not a consumer."""

import json
import shutil
import sys
import threading
import time
from pathlib import Path
from uuid import uuid4

from azure.core.exceptions import (
    AzureError,
    HttpResponseError,
    ResourceModifiedError,
    ResourceNotFoundError,
)
from loguru import logger

from app.cloud.checkpoints import Checkpoints, NeedsReview
from app.cloud.models import CloudRequest
from app.cloud.settings import configure_providers, identifier
from app.cloud.store import ACTIVE, TERMINAL, OwnershipLost, json_bytes, store


class Heartbeat:
    def __init__(self, storage, lease, message, task_id, owner):
        self.storage, self.lease, self.message = storage, lease, message
        self.task_id, self.owner = task_id, owner
        self.stop = threading.Event()
        self.lost = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.log_file = None

    def check(self):
        if self.lost.is_set():
            raise OwnershipLost("Lease renewal failed; refusing additional work")
        entity = self.storage.task(self.task_id)
        if (
            entity.get("owner") != self.owner
            or entity.get("lease_until", 0) < time.time()
        ):
            raise OwnershipLost("Task is no longer owned by this worker")

    def run(self):
        while not self.stop.wait(15):
            try:
                self.lease.renew()
                result = self.storage.queue.update_message(
                    self.message.id,
                    self.message.pop_receipt,
                    visibility_timeout=90,
                )
                self.message.pop_receipt = result.pop_receipt
                self.storage.owned_update(
                    self.task_id, self.owner, lease_until=time.time() + 90
                )
                if self.log_file and self.log_file.is_file():
                    self.storage.put(
                        f"{self.task_id}/worker.log",
                        self.log_file.read_bytes()[-256_000:],
                        overwrite=True,
                        content_type="text/plain",
                    )
            except Exception:
                logger.exception("Lease renewal failed for task {}", self.task_id)
                self.lost.set()
                return

    def close(self):
        self.stop.set()
        self.thread.join(timeout=60)


def maintain(storage=None):
    storage = storage or store()
    for entity in storage.tasks():
        if entity["status"] not in ACTIVE:
            continue
        if (
            entity["status"] == "running"
            and entity.get("lease_until", 0) >= time.time()
        ):
            continue
        if entity["status"] == "queued" and entity["updated"] > time.time() - 180:
            continue
        try:
            if entity.get("attempts", 0) >= 3:
                storage.update(
                    entity,
                    status="failed",
                    error="Maximum recovery attempts exceeded",
                    stage="recovery",
                )
                storage.poison.send_message(
                    json.dumps({"task_id": entity["RowKey"], "reason": "attempt_limit"})
                )
            else:
                pending = storage.update(
                    entity, status="pending_dispatch", owner="", lease_until=0.0
                )
                storage.dispatch(pending)
        except ResourceModifiedError:
            logger.info(
                "Maintenance skipped concurrently updated task {}", entity["RowKey"]
            )
        except AzureError:
            logger.exception("Maintenance could not recover task {}", entity["RowKey"])
            raise


def work(storage=None):
    storage = storage or store()
    try:
        lease = storage.lease("worker")
    except HttpResponseError as exc:
        if exc.status_code == 409:
            logger.info("Another render worker holds the global execution lease")
            return
        raise
    heartbeat = None
    handler = None
    root = None
    try:
        messages = storage.queue.receive_messages(
            messages_per_page=1, visibility_timeout=90
        )
        message = next(iter(messages), None)
        if message is None:
            return
        try:
            body = json.loads(message.content)
            if body["schema"] != 1:
                raise ValueError("Unknown queue message version")
            task_id = identifier(body["task_id"])
            entity = storage.task(task_id)
        except (ValueError, TypeError, KeyError, ResourceNotFoundError):
            storage.poison.send_message(
                json.dumps({"reason": "invalid_message", "message_id": message.id})
            )
            storage.queue.delete_message(message.id, message.pop_receipt)
            return
        if entity["status"] in TERMINAL:
            storage.queue.delete_message(message.id, message.pop_receipt)
            return
        if entity.get("attempts", 0) >= 3:
            storage.update(
                entity,
                status="failed",
                error="Maximum recovery attempts exceeded",
                stage="recovery",
            )
            storage.poison.send_message(
                json.dumps({"task_id": task_id, "reason": "attempt_limit"})
            )
            storage.queue.delete_message(message.id, message.pop_receipt)
            return
        if entity["status"] == "running" and entity.get("lease_until", 0) > time.time():
            return
        owner = str(uuid4())
        try:
            entity = storage.update(
                entity,
                status="running",
                owner=owner,
                lease_until=time.time() + 90,
                attempts=entity.get("attempts", 0) + 1,
            )
        except ResourceModifiedError:
            return
        heartbeat = Heartbeat(storage, lease, message, task_id, owner)
        heartbeat.thread.start()
        from app.utils import utils
        from app.cloud.pipeline import run

        root = Path(utils.task_dir(task_id)).resolve()
        log_file = root / "worker.log"
        heartbeat.log_file = log_file
        handler = logger.add(
            str(log_file), level="INFO", format="{time} {level} {message}"
        )
        checkpoint = Checkpoints(storage, task_id, root, heartbeat.check)
        try:
            manifest = storage.get_json(f"{task_id}/manifest.json")
            configure_providers(manifest["providers"])
            request = CloudRequest.model_validate(manifest["request"])
            result = run(
                request,
                checkpoint,
                lambda **values: storage.owned_update(task_id, owner, **values),
            )
            heartbeat.check()
            artifact_manifest = {"result": result, "artifacts": checkpoint.artifacts}
            # Publishing this immutable index is the commit point for media delivery.
            existing = storage.optional_json(f"{task_id}/result.json")
            if existing is None:
                storage.put(f"{task_id}/result.json", json_bytes(artifact_manifest))
            elif existing != artifact_manifest:
                raise NeedsReview("Conflicting task result")
            storage.owned_update(
                task_id,
                owner,
                status="succeeded",
                progress=100,
                stage="complete",
                error="",
            )
        except OwnershipLost:
            logger.exception("Worker ownership lost; message left for recovery")
            raise
        except AzureError:
            logger.exception(
                "Storage unavailable; leaving the task lease for maintenance recovery"
            )
            raise
        except Exception as exc:
            status = "needs_review" if isinstance(exc, NeedsReview) else "failed"
            # Do not log provider exception bodies or credentials in public diagnostics.
            error = (
                str(exc)
                if isinstance(exc, (NeedsReview, ValueError))
                else type(exc).__name__
            )
            logger.error("Task {} ended as {}: {}", task_id, status, error)
            storage.owned_update(task_id, owner, status=status, error=error[:2000])
        finally:
            logger.remove(handler)
            handler = None
            storage.put(
                f"{task_id}/worker.log",
                log_file.read_bytes()[-256_000:],
                overwrite=True,
                content_type="text/plain",
            )
        heartbeat.close()
        heartbeat.check()
        storage.queue.delete_message(message.id, message.pop_receipt)
    finally:
        if heartbeat:
            heartbeat.close()
        if handler is not None:
            logger.remove(handler)
        try:
            lease.release()
        except HttpResponseError as exc:
            if exc.status_code not in (409, 412):
                raise
            logger.warning("Worker lease already expired or was replaced")
        if root is not None:
            # task_id was validated as UUID; never remove a shared storage root.
            shutil.rmtree(root)


def main():
    configure_providers()
    if sys.argv[1:] == ["maintain"]:
        maintain()
    elif not sys.argv[1:]:
        work()
    else:
        raise SystemExit("Usage: python -m app.cloud.worker [maintain]")


if __name__ == "__main__":
    main()
