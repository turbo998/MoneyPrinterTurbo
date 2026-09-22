from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models.schema import VideoParams

VOICES = (
    "zh-CN-XiaoxiaoNeural-V2",
    "zh-CN-YunxiNeural-V2",
    "en-US-JennyNeural-V2",
    "en-US-AvaMultilingualNeural-V2",
)
STOPS = ("script", "terms", "audio", "subtitle", "materials", "video")
MAX_FILE_BYTES = 100 * 1024 * 1024
MAX_TASK_BYTES = 400 * 1024 * 1024


class CloudRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    params: VideoParams
    stop_at: Literal["script", "terms", "audio", "subtitle", "materials", "video"] = (
        "video"
    )
    image_count: int = Field(default=2, ge=1, le=8)
    uploads: list[str] = Field(default_factory=list, max_length=8)
    bgm_upload: str = ""
    reuse_audio_task_id: str = ""

    @model_validator(mode="after")
    def bounded(self):
        p = self.params
        if not 1 <= len(p.video_subject.strip()) <= 300:
            raise ValueError("Topic must contain 1-300 characters")
        validate_script(p.video_script)
        if self.reuse_audio_task_id and not p.video_script:
            raise ValueError("Reusing a preview requires its exact narration text")
        if p.video_count != 1 or p.paragraph_number != 1 or p.n_threads != 2:
            raise ValueError(
                "Cloud mode permits one video, one paragraph and two render threads"
            )
        if p.video_source not in ("local", "openai_image", "azure_mixed"):
            raise ValueError(
                "Cloud sources: uploaded licensed media, Foundry images, or mixed"
            )
        if p.voice_name not in VOICES:
            raise ValueError(
                "Choose a verified Azure Neural voice; Preview voices are disabled"
            )
        if p.voice_rate is None or not 0.8 <= p.voice_rate <= 1.3:
            raise ValueError("Cloud speech rate must be 0.8-1.3")
        if (
            p.voice_volume != 1.0
            or p.bgm_volume is None
            or not 0 <= p.bgm_volume <= 0.5
        ):
            raise ValueError(
                "Cloud narration volume is 1.0; background music volume must be 0-0.5"
            )
        if p.video_clip_duration > 15 or p.video_clip_speed != 1.0:
            raise ValueError("Cloud clips must be 1-15 seconds at normal speed")
        if p.video_materials or p.custom_audio_file or p.bgm_file:
            raise ValueError("Server paths and remote URLs are forbidden; use uploads")
        if p.bgm_type not in ("", "none", "custom"):
            raise ValueError(
                "Only disabled or uploaded licensed background music is supported"
            )
        if p.bgm_type == "custom" and not self.bgm_upload:
            raise ValueError("Upload licensed background music first")
        if p.font_name != "NotoSansCJK-Regular.ttc":
            raise ValueError("Cloud subtitles use the licensed Noto Sans CJK font")
        if not 20 <= p.font_size <= 100 or not 0 <= p.stroke_width <= 5:
            raise ValueError("Subtitle font size must be 20-100 and stroke width 0-5")
        if (
            p.video_source in ("local", "azure_mixed")
            and not self.uploads
            and self.stop_at in ("materials", "video")
        ):
            raise ValueError("This source requires uploaded materials")
        if p.video_terms:
            terms = (
                p.video_terms
                if isinstance(p.video_terms, list)
                else p.video_terms.split(",")
            )
            if len(terms) > 8 or any(
                not isinstance(t, str) or len(t) > 500 for t in terms
            ):
                raise ValueError(
                    "At most eight image prompts of 500 characters are allowed"
                )
        return self


def validate_script(text: str):
    # Conservative pre-charge bound, followed by measured audio-duration enforcement.
    if len(text) > 600 or len(text.split()) > 100:
        raise ValueError(
            "Narration is limited to 600 characters / 100 words and 60 seconds"
        )
