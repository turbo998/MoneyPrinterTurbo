import base64
import json
import time
from contextlib import nullcontext
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
from uuid import uuid4

import pytest
from azure.core.exceptions import (
    AzureError,
    HttpResponseError,
    ResourceExistsError,
    ResourceModifiedError,
    ResourceNotFoundError,
)
from azure.data.tables import TableEntity
from fastapi.testclient import TestClient

from app.cloud import api, settings
from app.cloud.checkpoints import Checkpoints, NeedsReview
from app.cloud.models import CloudRequest
from app.cloud.store import (
    CapacityError,
    OwnershipLost,
    Store,
    digest,
    json_bytes,
    public_task,
)
from app.services.azure_auth import azure_endpoint
from app.services.azure_speech import duration_ticks
from webui.cloud import principal

USER = "8922ff53-3609-44a8-92f0-fc46c7826929"
TENANT = "16b3c013-d300-468d-ac64-7eda0820b6d3"
ID = "7382c3f9-8996-460a-8b23-126543ebdd24"


@pytest.fixture(autouse=True)
def environment(monkeypatch):
    monkeypatch.setenv("MPT_ALLOWED_OIDS", USER)
    monkeypatch.setenv("MPT_TENANT_ID", TENANT)
    monkeypatch.setenv("MPT_INTERNAL_API_TOKEN", "x" * 40)
    for key in settings.PROVIDER_VARIABLES:
        monkeypatch.setenv(
            key,
            "https://example.openai.azure.com" if "ENDPOINT" in key else "deployment",
        )
    settings.allowed_users.cache_clear()
    yield
    settings.allowed_users.cache_clear()


def request_data(**overrides):
    params = {
        "video_subject": "A calm garden",
        "video_script": "Welcome to the garden.",
        "video_source": "openai_image",
        "voice_name": "en-US-JennyNeural-V2",
        "font_name": "NotoSansCJK-Regular.ttc",
        "bgm_type": "",
    }
    params.update(overrides)
    return {"params": params}


def test_storage_clients_construct_with_entra_credential(monkeypatch):
    from app.cloud import store as storage_module

    auth = Mock()
    monkeypatch.setenv("MPT_STORAGE_ACCOUNT", "teststorage")
    monkeypatch.setattr(storage_module, "credential", lambda: auth)
    storage = Store()
    assert storage.blobs.url == "https://teststorage.blob.core.windows.net/tasks"
    assert storage.table.url == "https://teststorage.table.core.windows.net"
    assert storage.queue.url == "https://teststorage.queue.core.windows.net/tasks"
    assert storage.poison.url == "https://teststorage.queue.core.windows.net/poison"
    auth.get_token.assert_not_called()


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://example.openai.azure.com",
        "https://example.com",
        "https://example.openai.azure.com.evil.test",
        "https://user:password@x.openai.azure.com",
        "https://x.openai.azure.com:444",
        "https://x.openai.azure.com/?secret=1",
        "https://x.openai.azure.com/path",
        "https://x.openai.azure.com/#fragment",
    ],
)
def test_bearer_token_never_sent_to_untrusted_host(endpoint):
    with pytest.raises(ValueError):
        azure_endpoint(endpoint, v1=True)


def test_endpoint_and_timing_units():
    assert (
        azure_endpoint("https://x.openai.azure.com/openai/v1/")
        == "https://x.openai.azure.com"
    )
    assert azure_endpoint("https://x.openai.azure.com", v1=True).endswith("/openai/v1/")
    assert duration_ticks(timedelta(milliseconds=250)) == 2_500_000
    assert duration_ticks(123) == 123
    with pytest.raises(ValueError):
        duration_ticks("250")


@pytest.mark.parametrize(
    "changes",
    [
        {"video_count": 2},
        {"paragraph_number": 2},
        {"n_threads": 8},
        {"video_source": "sora"},
        {"voice_name": "zh-CN-XiaoxiaoNeural"},
        {"voice_rate": 2},
        {"video_clip_duration": 16},
        {"video_clip_speed": 2},
        {"video_materials": [{"url": "http://evil.test/video.mp4"}]},
        {"custom_audio_file": "/etc/passwd"},
        {"bgm_file": "../file.mp3"},
        {"bgm_type": "random"},
        {"font_name": "/etc/passwd"},
        {"font_size": 200},
        {"stroke_width": 20},
        {"video_subject": ""},
        {"video_script": "a" * 601},
        {"video_script": "word " * 101},
        {"bgm_type": "custom"},
        {"video_source": "local"},
        {"video_terms": ["x"] * 9},
        {"video_terms": ["x" * 501]},
        {"voice_volume": 10},
        {"bgm_volume": 1},
    ],
)
def test_cloud_boundaries_enforced_server_side(changes):
    with pytest.raises(ValueError):
        CloudRequest.model_validate(request_data(**changes))


@pytest.mark.parametrize("count", [0, 9])
def test_image_count_capped(count):
    with pytest.raises(ValueError):
        CloudRequest.model_validate({**request_data(), "image_count": count})


def test_principal_requires_matching_tenant_and_allowlist():
    def header(oid=USER, tenant=TENANT):
        data = {"claims": [{"typ": "oid", "val": oid}, {"typ": "tid", "val": tenant}]}
        return {
            "X-Ms-Client-Principal": base64.b64encode(
                json.dumps(data).encode()
            ).decode()
        }

    assert principal(header()) == USER
    for invalid in ({}, header(str(uuid4())), header(tenant=str(uuid4()))):
        with pytest.raises(PermissionError):
            principal(invalid)


class MemoryBlobs:
    def __init__(self):
        self.data = {}

    def put(self, key, data, *, overwrite=False, **kwargs):
        if key in self.data and not overwrite:
            raise ResourceExistsError("exists")
        self.data[key] = data

    def get_bytes(self, key, *args):
        if key not in self.data:
            raise ResourceNotFoundError("missing")
        return self.data[key]

    def get_json(self, key):
        return json.loads(self.get_bytes(key))

    def optional_json(self, key):
        return self.get_json(key) if key in self.data else None


def test_checkpoint_restores_without_second_paid_call(tmp_path):
    storage = MemoryBlobs()
    owner = Mock()
    cp = Checkpoints(storage, ID, tmp_path, owner)
    file = tmp_path / "audio.mp3"
    file.write_bytes(b"audio")
    action = Mock(return_value=({"duration": 1}, [file]))
    assert cp.run("audio", action, paid=True) == {"duration": 1}
    file.unlink()
    recovered = Checkpoints(storage, ID, tmp_path, owner)
    assert recovered.run("audio", action, paid=True) == {"duration": 1}
    assert file.read_bytes() == b"audio"
    action.assert_called_once()
    assert recovered.artifacts["audio.mp3"]["sha256"] == digest(b"audio")


def test_paid_timeout_never_replays(tmp_path):
    cp = Checkpoints(MemoryBlobs(), ID, tmp_path, lambda: None)
    action = Mock(side_effect=TimeoutError("lost POST response"))
    with pytest.raises(NeedsReview):
        cp.run("image-0", action, paid=True)
    with pytest.raises(NeedsReview, match="previous paid submission"):
        cp.run("image-0", action, paid=True)
    action.assert_called_once()


def test_safe_stage_can_retry(tmp_path):
    cp = Checkpoints(MemoryBlobs(), ID, tmp_path, lambda: None)
    with pytest.raises(OSError):
        cp.run("video", Mock(side_effect=OSError("disk full")))
    assert cp.run("video", lambda: ({"ok": True}, [])) == {"ok": True}


def test_result_upload_failure_keeps_paid_fence(tmp_path):
    storage = MemoryBlobs()
    original_put = storage.put

    def fail_commit(key, data, **kwargs):
        if key.endswith("done.json"):
            raise OSError("storage unavailable")
        return original_put(key, data, **kwargs)

    storage.put = fail_commit
    cp = Checkpoints(storage, ID, tmp_path, lambda: None)
    action = Mock(return_value=({}, []))
    with pytest.raises(NeedsReview):
        cp.run("audio", action, paid=True)
    storage.put = original_put
    with pytest.raises(NeedsReview):
        cp.run("audio", action, paid=True)
    action.assert_called_once()


@pytest.mark.parametrize("case", ["missing", "corrupt", "escape"])
def test_invalid_checkpoint_never_regenerates(tmp_path, case):
    storage = MemoryBlobs()
    cp = Checkpoints(storage, ID, tmp_path, lambda: None)
    entry = {
        "path": "../escape" if case == "escape" else "file",
        "blob": "blob",
        "size": 4,
        "sha256": digest(b"data"),
    }
    if case == "corrupt":
        storage.put("blob", b"bad")
    storage.put(
        f"{ID}/checkpoints/audio/done.json", json_bytes({"data": {}, "files": [entry]})
    )
    action = Mock()
    with pytest.raises((NeedsReview, ValueError)):
        cp.run("audio", action, paid=True)
    action.assert_not_called()


class FakeTable:
    def __init__(self):
        self.rows = {}

    def get_entity(self, partition, key):
        if key not in self.rows:
            raise ResourceNotFoundError("missing")
        values, version = self.rows[key]
        entity = TableEntity(values)
        entity._metadata = {"etag": str(version)}
        return entity

    def create_entity(self, values):
        if values["RowKey"] in self.rows:
            raise ResourceExistsError("exists")
        self.rows[values["RowKey"]] = (dict(values), 1)

    def update_entity(self, values, *, etag, **kwargs):
        _, version = self.rows[values["RowKey"]]
        if etag != str(version):
            raise ResourceModifiedError("etag mismatch")
        self.rows[values["RowKey"]] = (dict(values), version + 1)

    def query_entities(self, query):
        return [self.get_entity("tasks", key) for key in self.rows]


def fake_store():
    storage = Store.__new__(Store)
    memory = MemoryBlobs()
    storage.put, storage.get_json = memory.put, memory.get_json
    storage.get_bytes, storage.optional_json = memory.get_bytes, memory.optional_json
    storage.table = FakeTable()
    storage.queue = Mock()
    storage.poison = Mock()
    storage.admission = lambda: nullcontext()
    return storage


def test_submission_is_idempotent_and_immutable():
    storage = fake_store()
    request = CloudRequest.model_validate(request_data())
    result = storage.submit(ID, USER, request)
    assert result["status"] == "queued"
    assert storage.submit(ID, USER, request)["task_id"] == ID
    storage.queue.send_message.assert_called_once()
    changed = CloudRequest.model_validate(request_data(video_subject="different"))
    with pytest.raises(ValueError, match="different request"):
        storage.submit(ID, USER, changed)


def test_queue_admission_limit_and_unauthorized():
    storage = fake_store()
    body = CloudRequest.model_validate(request_data())
    for _ in range(10):
        storage.submit(str(uuid4()), USER, body)
    with pytest.raises(CapacityError):
        storage.submit(str(uuid4()), USER, body)
    with pytest.raises(PermissionError):
        storage.submit(str(uuid4()), str(uuid4()), body)
    assert storage.queue.send_message.call_count == 10


def test_etag_claim_and_expired_lease():
    storage = fake_store()
    storage.submit(ID, USER, CloudRequest.model_validate(request_data()))
    first, stale = storage.task(ID), storage.task(ID)
    storage.update(
        first, owner="worker", lease_until=time.time() + 60, status="running"
    )
    with pytest.raises(ResourceModifiedError):
        storage.update(stale, owner="other")
    with pytest.raises(OwnershipLost):
        storage.owned_update(ID, "other", progress=20)
    assert storage.owned_update(ID, "worker", progress=20)["progress"] == 20
    storage.update(storage.task(ID), lease_until=0.0)
    with pytest.raises(OwnershipLost):
        storage.owned_update(ID, "worker", progress=40)


def test_maintenance_repairs_dispatch_and_expired_tasks():
    from app.cloud.worker import maintain

    storage = fake_store()
    storage.submit(ID, USER, CloudRequest.model_validate(request_data()))
    storage.update(storage.task(ID), status="running", owner="dead", lease_until=0.0)
    maintain(storage)
    assert storage.task(ID)["status"] == "queued"
    storage.update(storage.task(ID), status="running", attempts=3, lease_until=0.0)
    maintain(storage)
    assert storage.task(ID)["status"] == "failed"
    storage.poison.send_message.assert_called_once()


def test_api_requires_both_service_token_and_allowed_user(monkeypatch):
    monkeypatch.setattr(api, "store", lambda: fake_store())
    client = TestClient(api.app)
    assert client.get("/health").status_code == 200
    assert client.get("/api/v1/tasks").status_code == 401
    assert (
        client.get(
            "/api/v1/tasks", headers={"Authorization": "Bearer " + "x" * 40}
        ).status_code
        == 403
    )
    assert (
        client.get(
            "/api/v1/tasks",
            headers={"Authorization": "Bearer " + "x" * 40, "X-MPT-USER": USER},
        ).status_code
        == 200
    )


def test_api_submission_history_artifacts_and_owner(monkeypatch):
    storage = fake_store()
    monkeypatch.setattr(api, "store", lambda: storage)
    client = TestClient(
        api.app, headers={"Authorization": "Bearer " + "x" * 40, "X-MPT-USER": USER}
    )
    result = client.post(
        "/api/v1/videos", json=request_data(), headers={"Idempotency-Key": ID}
    )
    assert result.status_code == 202, result.text
    assert client.get("/api/v1/tasks").json()["data"]["total"] == 1
    assert client.get(f"/api/v1/tasks/{ID}").json()["data"]["status"] == "queued"
    assert client.get(f"/api/v1/tasks/{ID}/artifacts/audio.mp3").status_code == 409
    assert client.get(f"/api/v1/tasks/{uuid4()}").status_code == 404
    storage.update(storage.task(ID), user=str(uuid4()))
    assert client.get(f"/api/v1/tasks/{ID}").status_code == 404


def test_public_states_do_not_leak_internal_leases():
    for status, numeric in [
        ("succeeded", 1),
        ("failed", -1),
        ("needs_review", -1),
        ("running", 4),
    ]:
        value = public_task(
            {"RowKey": ID, "created": 1, "status": status, "owner": "secret"}
        )
        assert value["state"] == numeric
        assert "owner" not in value


def test_api_rejects_oversize_body_before_parsing(monkeypatch):
    monkeypatch.setattr(api, "store", lambda: fake_store())
    client = TestClient(
        api.app, headers={"Authorization": "Bearer " + "x" * 40, "X-MPT-USER": USER}
    )
    response = client.post(
        "/api/v1/videos",
        content=b"x" * 70000,
        headers={"Content-Type": "application/json"},
    )
    assert response.status_code == 413


def test_cloud_keyless_image_single_post(monkeypatch):
    from app.config import config
    from app.services import material
    from app.services import azure_auth

    monkeypatch.setitem(config.app, "openai_image_auth_mode", "entra")
    monkeypatch.setitem(
        config.app,
        "openai_image_base_url",
        "https://images.openai.azure.com/openai/v1/",
    )
    monkeypatch.setattr(azure_auth, "token_provider", lambda: lambda: "test-token")
    post = Mock(
        return_value=SimpleNamespace(
            raise_for_status=lambda: None,
            json=lambda: {"data": [{"b64_json": base64.b64encode(b"png").decode()}]},
        )
    )
    monkeypatch.setattr(material.requests, "post", post)
    assert (
        material._request_openai_image(
            "https://images.openai.azure.com/openai/v1/images/generations", {}
        )[0]
        == b"png"
    )
    assert post.call_count == 1
    post.side_effect = TimeoutError("unknown")
    with pytest.raises(TimeoutError):
        material._request_openai_image(
            "https://images.openai.azure.com/openai/v1/images/generations", {}
        )
    assert post.call_count == 2
    with pytest.raises(ValueError):
        material._request_openai_image("https://evil.test/images/generations", {})
    assert post.call_count == 2


@pytest.fixture
def pipeline_mock(monkeypatch, tmp_path):
    from app.cloud import pipeline

    monkeypatch.setattr(
        pipeline.task.utils, "task_dir", lambda task_id=None: str(tmp_path)
    )
    monkeypatch.setattr(
        pipeline.llm, "_generate_response", Mock(return_value="A calm garden.")
    )

    def synth(text, name, file, rate):
        Path(file).write_bytes(b"audio")
        return SimpleNamespace(
            subs=["A", "calm", "garden"],
            offset=[(0, 5000000), (5000000, 10000000), (10000000, 15000000)],
        )

    monkeypatch.setattr(pipeline.voice, "azure_tts_v2", Mock(side_effect=synth))

    def subtitles(maker, text, file, **kwargs):
        Path(file).write_text("1\n00:00:00,000 --> 00:00:01,500\nA calm garden.\n\n")

    monkeypatch.setattr(pipeline.voice, "create_subtitle", subtitles)

    def probe(file):
        if str(file).endswith(".mp3"):
            return {"format": {"duration": "2.0"}}
        return {
            "streams": [
                {
                    "codec_type": "video",
                    "codec_name": "h264",
                    "width": 1080,
                    "height": 1920,
                    "r_frame_rate": "30/1",
                    "duration": "2.0",
                },
                {"codec_type": "audio", "codec_name": "aac", "duration": "2.0"},
            ],
            "format": {"duration": "2.0"},
        }

    monkeypatch.setattr(pipeline, "probe", probe)
    monkeypatch.setattr(
        pipeline.material, "_openai_image_endpoint", lambda: ("endpoint", "model")
    )
    monkeypatch.setattr(
        pipeline.material, "_request_openai_image", Mock(return_value=(b"image", ""))
    )

    def image(raw, directory):
        file = tmp_path / "image.png"
        file.write_bytes(raw)
        return str(file), 1024, 1536

    monkeypatch.setattr(pipeline.material, "_save_openai_image_file", image)

    def motion(file, duration):
        result = tmp_path / "motion.mp4"
        result.write_bytes(b"clip")
        return str(result)

    monkeypatch.setattr(pipeline.material, "_render_openai_image_video", motion)

    def render(*args):
        file = tmp_path / "final-1.mp4"
        file.write_bytes(b"video")
        return [str(file)], [], []

    monkeypatch.setattr(
        pipeline.task, "generate_final_videos", Mock(side_effect=render)
    )
    return pipeline


@pytest.mark.parametrize(
    "stop", ["script", "terms", "audio", "subtitle", "materials", "video"]
)
def test_pipeline_all_stop_at_paths_checkpoint_and_restore(
    pipeline_mock, tmp_path, stop
):
    storage = MemoryBlobs()
    request = CloudRequest.model_validate(
        {**request_data(), "image_count": 1, "stop_at": stop}
    )
    first = pipeline_mock.run(
        request, Checkpoints(storage, ID, tmp_path, lambda: None), Mock()
    )
    before = pipeline_mock.voice.azure_tts_v2.call_count
    second = pipeline_mock.run(
        request, Checkpoints(storage, ID, tmp_path, lambda: None), Mock()
    )
    assert first == second
    assert pipeline_mock.voice.azure_tts_v2.call_count == before
    assert pipeline_mock.material._request_openai_image.call_count <= 1


def test_pipeline_generated_script_and_measured_duration(pipeline_mock, tmp_path):
    request = CloudRequest.model_validate(
        {**request_data(video_script=""), "stop_at": "audio"}
    )
    result = pipeline_mock.run(
        request, Checkpoints(MemoryBlobs(), ID, tmp_path, lambda: None), Mock()
    )
    assert result["script"] == "A calm garden."
    assert result["duration"] == 2.0
    pipeline_mock.llm._generate_response.assert_called_once()


def test_pipeline_rejects_audio_over_limit_before_images(
    pipeline_mock, tmp_path, monkeypatch
):
    monkeypatch.setattr(
        pipeline_mock, "probe", lambda file: {"format": {"duration": "60.01"}}
    )
    request = CloudRequest.model_validate(request_data())
    with pytest.raises(ValueError, match="60-second"):
        pipeline_mock.run(
            request, Checkpoints(MemoryBlobs(), ID, tmp_path, lambda: None), Mock()
        )
    pipeline_mock.material._request_openai_image.assert_not_called()


def test_pipeline_invalid_subtitles_never_produce_success(
    pipeline_mock, tmp_path, monkeypatch
):
    def invalid(maker, text, file, **kwargs):
        Path(file).write_text("1\n00:00:00,000 --> 00:00:04,500\nA garden.\n\n")

    monkeypatch.setattr(pipeline_mock.voice, "create_subtitle", invalid)
    with pytest.raises(ValueError, match="out-of-range"):
        pipeline_mock.run(
            CloudRequest.model_validate(request_data()),
            Checkpoints(MemoryBlobs(), ID, tmp_path, lambda: None),
            Mock(),
        )


def test_audio_preview_reuse_validates_exact_snapshot():
    storage = fake_store()
    request = CloudRequest.model_validate({**request_data(), "stop_at": "audio"})
    storage.submit(ID, USER, request)
    storage.update(storage.task(ID), status="succeeded")
    storage.put(
        f"{ID}/checkpoints/script/done.json",
        json_bytes({"data": {"script": request.params.video_script}}),
    )
    storage.put(
        f"{ID}/checkpoints/audio/done.json",
        json_bytes({"data": {"audio": "audio.mp3"}}),
    )
    reuse = CloudRequest.model_validate({**request_data(), "reuse_audio_task_id": ID})
    storage.submit(str(uuid4()), USER, reuse)
    altered = CloudRequest.model_validate(
        {**request_data(voice_rate=1.1), "reuse_audio_task_id": ID}
    )
    with pytest.raises(ValueError, match="changed"):
        storage.submit(str(uuid4()), USER, altered)


def test_worker_duplicate_terminal_ack_without_pipeline(monkeypatch):
    from app.cloud.worker import work

    storage = fake_store()
    storage.submit(ID, USER, CloudRequest.model_validate(request_data()))
    storage.update(storage.task(ID), status="succeeded")
    message = SimpleNamespace(
        content=json.dumps({"schema": 1, "task_id": ID}),
        id="message",
        pop_receipt="receipt",
    )
    storage.queue.receive_messages.return_value = iter([message])
    storage.lease = Mock(return_value=Mock())
    work(storage)
    storage.queue.delete_message.assert_called_once_with("message", "receipt")


def test_worker_poison_invalid_message():
    from app.cloud.worker import work

    storage = fake_store()
    message = SimpleNamespace(content="not json", id="message", pop_receipt="receipt")
    storage.queue.receive_messages.return_value = iter([message])
    storage.lease = Mock(return_value=Mock())
    work(storage)
    storage.poison.send_message.assert_called_once()
    storage.queue.delete_message.assert_called_once()


@pytest.fixture
def executing_store(monkeypatch, pipeline_mock):
    from app.cloud import worker

    monkeypatch.setattr(worker, "configure_providers", Mock())
    storage = fake_store()
    storage.submit(
        ID, USER, CloudRequest.model_validate({**request_data(), "image_count": 1})
    )
    message = SimpleNamespace(
        content=json.dumps({"schema": 1, "task_id": ID}),
        id="message",
        pop_receipt="receipt",
    )
    storage.queue.receive_messages.side_effect = lambda **kwargs: iter([message])
    storage.lease = Mock(return_value=Mock())
    return storage


def test_worker_publishes_result_and_duplicate_never_charges(
    executing_store, pipeline_mock, tmp_path
):
    from app.cloud.worker import work

    work(executing_store)
    assert executing_store.task(ID)["status"] == "succeeded"
    result = executing_store.get_json(f"{ID}/result.json")
    assert result["result"]["width"] == 1080
    assert "final-1.mp4" in result["artifacts"]
    assert not tmp_path.exists()
    work(executing_store)
    pipeline_mock.voice.azure_tts_v2.assert_called_once()
    pipeline_mock.material._request_openai_image.assert_called_once()
    assert executing_store.queue.delete_message.call_count == 2


def test_worker_recovers_after_result_commit_without_repaying(
    executing_store, pipeline_mock, monkeypatch
):
    from app.cloud.worker import work

    update = executing_store.owned_update

    def lose_response(task_id, owner, **values):
        if values.get("status") == "succeeded":
            raise AzureError("State commit unavailable")
        return update(task_id, owner, **values)

    monkeypatch.setattr(executing_store, "owned_update", lose_response)
    with pytest.raises(AzureError):
        work(executing_store)
    assert executing_store.get_json(f"{ID}/result.json")
    assert executing_store.task(ID)["status"] == "running"
    executing_store.queue.delete_message.assert_not_called()
    monkeypatch.setattr(executing_store, "owned_update", update)
    executing_store.update(executing_store.task(ID), lease_until=0.0)
    work(executing_store)
    assert executing_store.task(ID)["status"] == "succeeded"
    assert executing_store.task(ID)["attempts"] == 2
    pipeline_mock.voice.azure_tts_v2.assert_called_once()
    pipeline_mock.material._request_openai_image.assert_called_once()


def test_worker_unknown_paid_result_requires_review(executing_store, pipeline_mock):
    from app.cloud.worker import work

    pipeline_mock.voice.azure_tts_v2.side_effect = TimeoutError("Lost response")
    work(executing_store)
    assert executing_store.task(ID)["status"] == "needs_review"
    assert "no automatic resubmission" in executing_store.task(ID)["error"]
    work(executing_store)
    pipeline_mock.voice.azure_tts_v2.assert_called_once()
    pipeline_mock.material._request_openai_image.assert_not_called()


def test_worker_safe_render_failure_is_explicit(executing_store, pipeline_mock):
    from app.cloud.worker import work

    pipeline_mock.task.generate_final_videos.side_effect = ValueError("Invalid render")
    work(executing_store)
    assert executing_store.task(ID)["status"] == "failed"
    assert executing_store.task(ID)["error"] == "Invalid render"
    executing_store.queue.delete_message.assert_called_once()


@pytest.mark.parametrize("status", ["empty", "busy", "exhausted"])
def test_worker_nonprocessing_paths(executing_store, pipeline_mock, status):
    from app.cloud.worker import work

    if status == "empty":
        executing_store.queue.receive_messages.side_effect = lambda **kwargs: iter([])
    elif status == "busy":
        executing_store.update(
            executing_store.task(ID), status="running", lease_until=time.time() + 90
        )
    else:
        executing_store.update(executing_store.task(ID), attempts=3)
    work(executing_store)
    pipeline_mock.voice.azure_tts_v2.assert_not_called()
    executing_store.lease.return_value.release.assert_called_once()
    if status == "exhausted":
        assert executing_store.task(ID)["status"] == "failed"
        executing_store.poison.send_message.assert_called_once()
    else:
        executing_store.queue.delete_message.assert_not_called()


def test_worker_global_lease_excludes_parallel_execution():
    from app.cloud.worker import work

    storage = fake_store()
    error = HttpResponseError("Already leased")
    error.status_code = 409
    storage.lease = Mock(side_effect=error)
    work(storage)
    storage.queue.receive_messages.assert_not_called()
    error.status_code = 403
    with pytest.raises(HttpResponseError):
        work(storage)


def test_heartbeat_renews_queue_receipt_and_uploads_logs(tmp_path):
    from app.cloud.worker import Heartbeat

    storage, lease = Mock(), Mock()
    message = SimpleNamespace(id="message", pop_receipt="old")
    storage.queue.update_message.return_value = SimpleNamespace(pop_receipt="new")
    heartbeat = Heartbeat(storage, lease, message, ID, "owner")
    heartbeat.stop = Mock()
    heartbeat.stop.wait.side_effect = [False, True]
    heartbeat.log_file = tmp_path / "worker.log"
    heartbeat.log_file.write_bytes(b"task progress")
    heartbeat.run()
    lease.renew.assert_called_once()
    assert message.pop_receipt == "new"
    storage.owned_update.assert_called_once()
    storage.put.assert_called_once()
    assert not heartbeat.lost.is_set()


def test_heartbeat_failure_fences_further_work():
    from app.cloud.worker import Heartbeat

    storage, lease = Mock(), Mock()
    lease.renew.side_effect = AzureError("Unavailable")
    heartbeat = Heartbeat(storage, lease, Mock(), ID, "owner")
    heartbeat.stop = Mock()
    heartbeat.stop.wait.return_value = False
    heartbeat.run()
    with pytest.raises(OwnershipLost):
        heartbeat.check()
    storage.queue.update_message.assert_not_called()
