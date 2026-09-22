"""Cloud-mode panels inside the original Streamlit shell and stylesheet."""

import base64
import json
import os
from uuid import uuid4

import requests
import streamlit as st

from app.cloud.models import VOICES
from app.cloud.settings import allowed_users, identifier, required


def principal(headers):
    try:
        raw = headers.get("X-Ms-Client-Principal", "")
        claims = json.loads(base64.b64decode(raw, validate=True))["claims"]
        values = {c["typ"]: c["val"] for c in claims}
        oid = values.get(
            "http://schemas.microsoft.com/identity/claims/objectidentifier",
            values.get("oid", ""),
        )
        tenant = values.get(
            "http://schemas.microsoft.com/identity/claims/tenantid",
            values.get("tid", ""),
        )
        user = identifier(oid)
        if tenant != required("MPT_TENANT_ID") or user not in allowed_users():
            raise PermissionError(
                "This account is not authorized for the demonstration"
            )
        return user
    except (ValueError, TypeError, KeyError) as exc:
        raise PermissionError(
            "Sign in through the configured single-tenant Azure endpoint"
        ) from exc


def request(method, path, user, **kwargs):
    base = os.getenv("MPT_INTERNAL_API_URL", "http://127.0.0.1:8080")
    if base != "http://127.0.0.1:8080":
        raise ValueError("Cloud API must remain on the loopback sidecar")
    headers = {
        "Authorization": f"Bearer {required('MPT_INTERNAL_API_TOKEN')}",
        "X-MPT-USER": user,
        **kwargs.pop("headers", {}),
    }
    response = requests.request(
        method, base + path, headers=headers, timeout=(5, 90), **kwargs
    )
    if not response.ok:
        try:
            detail = response.json().get("detail", "Request rejected")
        except ValueError:
            detail = f"HTTP {response.status_code}"
        raise RuntimeError(str(detail))
    return response


def render():
    st.title("MoneyPrinterTurbo")
    st.caption("Azure / Microsoft Foundry · Streamlit + FastAPI + FFmpeg")
    try:
        user = principal(st.context.headers)
    except PermissionError as exc:
        st.error(str(exc))
        st.stop()
    st.info(
        "Private cloud workspace: one render at a time, 60 seconds, at most 8 images "
        "and 10 active tasks. Settings are server-managed. Your tasks survive closing this page."
    )
    create, history, settings = st.tabs(
        ["Create video", "Tasks & downloads", "Azure settings"]
    )
    with settings:
        st.write(
            "Authentication: single-tenant Microsoft Entra ID; model/storage access: managed identity."
        )
        st.write(
            "Foundry images: low quality, n=1 per image. No model fallback or automatic uncertain POST retry."
        )
        st.warning(
            "MAI-Voice-2 / Flash are Preview and disabled until aligned subtitle support is verified."
        )
        st.write(
            "Background music is off by default. Upload only media you are licensed to use."
        )
        st.write(
            "Local mode retains the complete upstream provider/settings interface."
        )
    with create:
        script_tab, video_tab, audio_tab, subtitle_tab = st.tabs(
            ["Script", "Video", "Audio", "Subtitles"]
        )
        with script_tab:
            topic = st.text_input("Video subject", max_chars=300)
            script = st.text_area(
                "Narration (optional; Foundry writes it when empty)", max_chars=600
            )
            language = st.selectbox("Language", ["zh-CN", "en-US"])
            prompts = st.text_area(
                "Image prompts (one per line; optional)", max_chars=4000
            )
        with video_tab:
            source = st.selectbox(
                "Video source",
                ["openai_image", "local", "azure_mixed"],
                format_func=lambda v: {
                    "openai_image": "Foundry generated images",
                    "local": "Uploaded licensed media",
                    "azure_mixed": "Uploaded + Foundry images",
                }[v],
            )
            aspect = st.selectbox("Aspect ratio", ["9:16", "16:9", "1:1"])
            count = st.number_input("Generated images", 1, 8, 2)
            files = st.file_uploader(
                "Licensed video / images (100 MiB each, 400 MiB total)",
                type=["mp4", "mov", "webm", "png", "jpg", "jpeg"],
                accept_multiple_files=True,
            )
        with audio_tab:
            name = st.selectbox("Azure Speech voice", VOICES)
            rate = st.slider("Voice rate", 0.8, 1.3, 1.0, 0.05)
            music = st.file_uploader(
                "Optional licensed background music", type=["mp3", "wav", "m4a"]
            )
            preview_id = st.text_input(
                "Reuse completed audio task ID (optional)",
                help="Reuse its exact narration, voice and rate to avoid paying for synthesis twice.",
            )
        with subtitle_tab:
            subtitle_enabled = st.checkbox("Enable subtitles", value=True)
            subtitle_mode = st.selectbox(
                "Subtitle display", ["sentence", "word_by_word"]
            )
            st.caption(
                "Noto Sans CJK (SIL Open Font License); timestamps from the same Speech synthesis."
            )
        action = st.selectbox(
            "Generate", ["video", "script", "audio", "subtitle", "terms", "materials"]
        )
        if st.button("Submit task", type="primary"):
            try:
                if (
                    len(files) > 8
                    or sum(f.size for f in files) + (music.size if music else 0)
                    > 400 * 1024 * 1024
                ):
                    raise ValueError(
                        "At most eight media files and 400 MiB of total inputs are allowed"
                    )
                uploads = [
                    request(
                        "POST",
                        "/api/v1/uploads",
                        user,
                        files={"file": (f.name, f.getvalue())},
                    ).json()["data"]["upload"]
                    for f in files
                ]
                bgm = (
                    request(
                        "POST",
                        "/api/v1/uploads",
                        user,
                        files={"file": (music.name, music.getvalue())},
                    ).json()["data"]["upload"]
                    if music
                    else ""
                )
                body = {
                    "params": {
                        "video_subject": topic,
                        "video_script": script,
                        "video_language": language,
                        "video_terms": [
                            p.strip() for p in prompts.splitlines() if p.strip()
                        ]
                        or None,
                        "video_source": source,
                        "video_aspect": aspect,
                        "voice_name": name,
                        "voice_rate": rate,
                        "bgm_type": "custom" if bgm else "",
                        "font_name": "NotoSansCJK-Regular.ttc",
                        "subtitle_enabled": subtitle_enabled,
                        "subtitle_display_mode": subtitle_mode,
                    },
                    "stop_at": action,
                    "image_count": count,
                    "uploads": uploads,
                    "bgm_upload": bgm,
                    "reuse_audio_task_id": preview_id.strip(),
                }
                # Keep the ID after a transport error; the explicit retry button reuses the snapshot.
                st.session_state["cloud_pending"] = {"id": str(uuid4()), "body": body}
                _submit_pending(user)
            except (requests.RequestException, RuntimeError, ValueError) as exc:
                st.error(str(exc))
        if st.session_state.get("cloud_pending") and st.button(
            "Retry the same submission (no new task ID)"
        ):
            try:
                _submit_pending(user)
            except (requests.RequestException, RuntimeError, ValueError) as exc:
                st.error(str(exc))
    with history:
        _history(user)


def _submit_pending(user):
    pending = st.session_state["cloud_pending"]
    result = request(
        "POST",
        "/api/v1/videos",
        user,
        json=pending["body"],
        headers={"Idempotency-Key": pending["id"]},
    ).json()["data"]
    st.success(
        f"Accepted {result['task_id']} ({result['status']}). View Tasks & downloads."
    )
    st.session_state.pop("cloud_pending")


@st.fragment(run_every="5s")
def _history(user):
    try:
        rows = request("GET", "/api/v1/tasks", user).json()["data"]["tasks"]
        if not rows:
            st.write("No tasks yet.")
            return
        st.dataframe(rows, hide_index=True, use_container_width=True)
        selected = st.selectbox("Task", [r["task_id"] for r in rows])
        data = request("GET", f"/api/v1/tasks/{selected}", user).json()["data"]
        st.progress(data["progress"] / 100, text=f"{data['status']} · {data['stage']}")
        if data.get("error"):
            st.error(data["error"])
        if data.get("result"):
            st.json(data["result"])
        if st.button("Load logs"):
            st.code(request("GET", f"/api/v1/tasks/{selected}/logs", user).text)
        artifacts = data.get("artifacts", [])
        if artifacts:
            name = st.selectbox("Artifact", [a["name"] for a in artifacts])
            if st.button("Load selected artifact"):
                raw = request(
                    "GET", f"/api/v1/tasks/{selected}/artifacts/{name}", user
                ).content
                st.session_state["cloud_download"] = (selected, name, raw)
            cached = st.session_state.get("cloud_download")
            if cached and cached[:2] == (selected, name):
                raw = cached[2]
                if name.endswith(".mp4"):
                    st.video(raw)
                elif name.endswith(".mp3"):
                    st.audio(raw)
                st.download_button("Download", raw, file_name=name.replace("/", "_"))
    except (requests.RequestException, RuntimeError, ValueError) as exc:
        st.error(str(exc))
