"""Checkpointed adaptation of the existing Speech/material/MoviePy pipeline."""

import json
import subprocess
from pathlib import Path

from edge_tts import SubMaker

from app.cloud.models import CloudRequest, validate_script
from app.models.schema import VideoAspect, VideoConcatMode
from app.services import llm, material, subtitle, task, voice


def probe(path):
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return json.loads(result.stdout)


def run(request: CloudRequest, cp, report):
    params = request.params.model_copy(deep=True)
    params.video_aspect = VideoAspect(params.video_aspect)
    params.video_concat_mode = VideoConcatMode(params.video_concat_mode)
    root = cp.root
    root.mkdir(parents=True, exist_ok=True)

    def stage(name, action, *, paid=False, progress=0):
        report(stage=name, progress=progress)
        return cp.run(name, action, paid=paid)

    def script_action():
        prompt = llm.build_script_prompt(
            params.video_subject,
            params.video_language,
            1,
            params.video_script_prompt,
            params.custom_system_prompt,
        )
        text = llm._generate_response(
            f"{prompt}\nReturn narration only: at most 80 words or 160 Chinese characters."
        ).strip()
        validate_script(text)
        if not text:
            raise ValueError("Foundry returned empty narration")
        file = root / "script.txt"
        file.write_text(text, encoding="utf-8")
        return {"script": text}, [file]

    if params.video_script:

        def script_action():
            file = root / "script.txt"
            file.write_text(params.video_script, encoding="utf-8")
            return {"script": params.video_script}, [file]

    script = stage(
        "script", script_action, paid=not bool(params.video_script), progress=5
    )["script"]
    if request.stop_at == "script":
        return {"script": script}
    terms = params.video_terms
    if isinstance(terms, str):
        terms = [t.strip() for t in terms.split(",") if t.strip()]
    if not terms:
        terms = [params.video_subject]
    if request.stop_at == "terms":
        return stage("terms", lambda: ({"terms": terms}, []), progress=15)

    def audio_action():
        file = root / "audio.mp3"
        maker = voice.azure_tts_v2(
            script, params.voice_name, str(file), params.voice_rate
        )
        if not maker or not maker.offset:
            raise ValueError("Speech did not return an audio timeline")
        duration = float(probe(file)["format"]["duration"])
        return {
            "audio": file.name,
            "duration": duration,
            "words": maker.subs,
            "offsets": maker.offset,
            "timeline_source": "azure_speech_word_boundary",
        }, [file]

    if request.reuse_audio_task_id:

        def audio_action():
            previous = cp.store.get_json(
                f"{request.reuse_audio_task_id}/checkpoints/audio/done.json"
            )
            cp.restore(previous)
            return previous["data"], [root / f["path"] for f in previous["files"]]

    audio = stage(
        "audio", audio_action, paid=not bool(request.reuse_audio_task_id), progress=20
    )
    if not 0 < audio["duration"] <= 60:
        raise ValueError(
            "Measured narration exceeds the 60-second limit; shorten the script"
        )
    if request.stop_at == "audio":
        return {**audio, "script": script}
    audio_path = root / audio["audio"]

    def subtitle_action():
        maker = voice.ensure_legacy_submaker_fields(SubMaker())
        maker.subs = audio["words"]
        maker.offset = [tuple(pair) for pair in audio["offsets"]]
        file = root / "subtitle.srt"
        voice.create_subtitle(
            maker,
            script,
            str(file),
            word_level=params.subtitle_display_mode == "word_by_word",
        )
        if not file.is_file() or not file.stat().st_size:
            raise ValueError(
                "Speech timeline could not be aligned; no fallback synthesis or fake timings"
            )
        # The formatter is reused from upstream, but its result must remain within real audio.
        subtitles = subtitle.file_to_subtitles(str(file))
        if not subtitles:
            raise ValueError("Subtitle output is empty")
        last = 0.0
        for cue in subtitles:
            start, end = (timestamp_seconds(t) for t in cue[1].split(" --> "))
            if start < last or end <= start or end > audio["duration"] + 0.001:
                raise ValueError("Invalid or out-of-range subtitle timeline")
            last = end
        return {"subtitle": file.name, "cue_count": len(subtitles)}, [file]

    subtitles = (
        stage("subtitle", subtitle_action, progress=35)
        if params.subtitle_enabled
        else {}
    )
    if request.stop_at == "subtitle":
        return subtitles

    sources = []
    if params.video_source in ("local", "azure_mixed"):

        def input_action():
            from app.models.schema import MaterialInfo
            from app.services.video import preprocess_video

            paths = []
            for i, key in enumerate(request.uploads):
                dest = root / f"input-{i}{Path(key).suffix}"
                dest.write_bytes(cp.store.get_bytes(key))
                info = probe(dest)
                streams = info["streams"]
                image_or_video = next(
                    (s for s in streams if s["codec_type"] == "video"), None
                )
                if not image_or_video:
                    raise ValueError("Uploaded material has no video/image stream")
                if image_or_video["width"] * image_or_video["height"] > 16_777_216:
                    raise ValueError("Uploaded material exceeds 16 megapixels")
                paths.append(dest)
            prepared = preprocess_video(
                [MaterialInfo(provider="local", url=str(p)) for p in paths],
                clip_duration=params.video_clip_duration,
                material_root=str(root),
            )
            if len(prepared) != len(paths):
                raise ValueError("One or more uploaded materials could not be decoded")
            files = [Path(p.url) for p in prepared]
            return {"materials": [p.relative_to(root).as_posix() for p in files]}, files

        local = stage("inputs", input_action, progress=40)
        sources.extend(str(root / p) for p in local["materials"])

    if params.video_source in ("openai_image", "azure_mixed"):
        for index in range(request.image_count):
            prompt = terms[index % len(terms)]

            def image_action(index=index, prompt=prompt):
                endpoint, model = material._openai_image_endpoint()
                raw, error = material._request_openai_image(
                    endpoint,
                    {
                        "model": model,
                        "prompt": material._openai_image_prompt(prompt),
                        "n": 1,
                        "size": material._openai_image_size(params.video_aspect),
                        "quality": "low",
                        "output_format": "png",
                    },
                )
                if not raw:
                    raise ValueError(f"Foundry image generation failed: {error}")
                image, _, _ = material._save_openai_image_file(raw, str(root))
                return {"image": Path(image).name, "prompt": prompt}, [image]

            image = stage(
                f"image-{index}", image_action, paid=True, progress=45 + index * 3
            )

            def motion_action(image=image):
                result = material._render_openai_image_video(
                    str(root / image["image"]), params.video_clip_duration
                )
                if not result:
                    raise ValueError("Generated image could not be rendered")
                file = Path(result)
                return {"clip": file.relative_to(root).as_posix()}, [file]

            motion = stage(f"motion-{index}", motion_action, progress=65)
            sources.append(str(root / motion["clip"]))

    if not sources:
        raise ValueError("No usable video materials")
    if request.stop_at == "materials":
        return {"materials": [Path(p).relative_to(root).as_posix() for p in sources]}
    if request.bgm_upload:

        def bgm_action():
            file = root / f"bgm{Path(request.bgm_upload).suffix}"
            file.write_bytes(cp.store.get_bytes(request.bgm_upload))
            if not any(s["codec_type"] == "audio" for s in probe(file)["streams"]):
                raise ValueError("Background music has no audio stream")
            return {"bgm": file.name}, [file]

        bgm = stage("bgm", bgm_action, progress=70)
        params.bgm_file = str(root / bgm["bgm"])
    params.video_source = "local"
    task.save_script_data(cp.task_id, script, terms, params)

    def render_action():
        final, combined, warnings = task.generate_final_videos(
            cp.task_id,
            params,
            sources,
            str(audio_path),
            str(root / subtitles["subtitle"]) if subtitles else "",
            audio["duration"],
        )
        if warnings:
            raise RuntimeError(f"Render warnings require review: {warnings}")
        if len(final) != 1:
            raise ValueError("Expected exactly one output")
        info = probe(final[0])
        video_stream = next(s for s in info["streams"] if s["codec_type"] == "video")
        audio_stream = next(s for s in info["streams"] if s["codec_type"] == "audio")
        expected = VideoAspect(params.video_aspect).to_resolution()
        if (video_stream["width"], video_stream["height"]) != expected:
            raise ValueError("Rendered video resolution does not match the request")
        if video_stream["codec_name"] != "h264" or audio_stream["codec_name"] != "aac":
            raise ValueError("Rendered video must use H.264/AAC")
        numerator, denominator = video_stream["r_frame_rate"].split("/")
        fps = float(numerator) / float(denominator)
        if (
            abs(float(video_stream["duration"]) - float(audio_stream["duration"]))
            > 1 / fps + 0.001
        ):
            raise ValueError("Audio/video duration mismatch exceeds one frame")
        if float(info["format"]["duration"]) > 60 + 1 / fps:
            raise ValueError("Rendered output exceeds the duration limit")
        evidence = root / "ffprobe.json"
        evidence.write_text(json.dumps(info, indent=2), encoding="utf-8")
        return {
            "videos": [Path(p).name for p in final],
            "audio": audio["audio"],
            "subtitle": subtitles.get("subtitle", ""),
            "duration": audio["duration"],
            "width": expected[0],
            "height": expected[1],
            "fps": fps,
            "image_count": request.image_count
            if request.params.video_source != "local"
            else 0,
        }, [*final, evidence, root / "script.json"]

    return stage("video", render_action, progress=80)


def timestamp_seconds(value: str) -> float:
    hours, minutes, seconds = value.replace(",", ".").split(":")
    return int(hours) * 3600 + int(minutes) * 60 + float(seconds)
