"""A durable paid-request fence: an uncertain POST is never automatically replayed."""

import json
from pathlib import Path

from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError

from app.cloud.store import digest, json_bytes


class NeedsReview(RuntimeError):
    pass


class Checkpoints:
    def __init__(self, storage, task_id, root: Path, verify_owner):
        self.store, self.task_id, self.root = storage, task_id, root.resolve()
        self.verify_owner = verify_owner
        self.artifacts = {}

    def run(self, name, action, *, paid=False):
        self.verify_owner()
        prefix = f"{self.task_id}/checkpoints/{name}"
        complete = self.store.optional_json(f"{prefix}/done.json")
        if complete:
            self.restore(complete)
            return complete["data"]
        if paid:
            try:
                self.store.put(f"{prefix}/submitting.json", json_bytes({"stage": name}))
            except ResourceExistsError as exc:
                raise NeedsReview(
                    f"{name}: a previous paid submission has no durable result; "
                    "manual provider/billing review is required, not automatic retry"
                ) from exc
        self.verify_owner()
        try:
            data, files = action()
            data = json.loads(json_bytes(data))
            self.verify_owner()
            entries = []
            for path in files:
                path = Path(path).resolve()
                relative = path.relative_to(self.root).as_posix()
                raw = path.read_bytes()
                sha = digest(raw)
                key = f"{prefix}/{sha}/{path.name}"
                try:
                    self.store.put(key, raw)
                except ResourceExistsError:
                    pass
                if digest(self.store.get_bytes(key)) != sha:
                    raise ValueError("Uploaded artifact checksum mismatch")
                entry = {"path": relative, "blob": key, "sha256": sha, "size": len(raw)}
                entries.append(entry)
                self.artifacts[relative] = entry
            result = {"data": data, "files": entries}
            self.store.put(
                f"{prefix}/done.json",
                json_bytes(result),
                content_type="application/json",
            )
            return data
        except Exception as exc:
            if paid:
                raise NeedsReview(
                    f"{name}: paid operation or result persistence failed "
                    f"({type(exc).__name__}); no automatic resubmission"
                ) from exc
            raise

    def restore(self, complete):
        for entry in complete["files"]:
            destination = (self.root / entry["path"]).resolve()
            if not destination.is_relative_to(self.root):
                raise ValueError("Unsafe checkpoint path")
            try:
                raw = self.store.get_bytes(entry["blob"])
            except ResourceNotFoundError as exc:
                raise NeedsReview(
                    "Checkpoint data missing; do not regenerate paid assets"
                ) from exc
            if len(raw) != entry["size"] or digest(raw) != entry["sha256"]:
                raise NeedsReview("Checkpoint checksum mismatch")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)
            self.artifacts[entry["path"]] = entry
