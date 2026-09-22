import os
from functools import lru_cache
from uuid import UUID

from app.services.azure_auth import azure_endpoint


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"{name} is required in cloud mode")
    return value


def identifier(value: str) -> str:
    return str(UUID(value))


@lru_cache(maxsize=1)
def allowed_users() -> frozenset[str]:
    return frozenset(
        identifier(v.strip()) for v in required("MPT_ALLOWED_OIDS").split(",")
    )


PROVIDER_VARIABLES = (
    "MPT_TEXT_ENDPOINT",
    "MPT_TEXT_DEPLOYMENT",
    "MPT_IMAGE_ENDPOINT",
    "MPT_IMAGE_DEPLOYMENT",
    "MPT_SPEECH_ENDPOINT",
    "MPT_SPEECH_RESOURCE_ID",
    "MPT_SPEECH_REGION",
)


def provider_snapshot():
    return {key: required(key) for key in PROVIDER_VARIABLES}


def configure_providers(snapshot=None):
    from app.config import config

    values = snapshot or provider_snapshot()
    config.app.update(
        llm_provider="azure",
        azure_auth_mode="entra",
        azure_api_mode="v1",
        azure_base_url=azure_endpoint(values["MPT_TEXT_ENDPOINT"]),
        azure_model_name=values["MPT_TEXT_DEPLOYMENT"],
        azure_max_completion_tokens=512,
        openai_image_auth_mode="entra",
        openai_image_base_url=azure_endpoint(values["MPT_IMAGE_ENDPOINT"], v1=True),
        openai_image_model=values["MPT_IMAGE_DEPLOYMENT"],
        subtitle_provider="edge",  # Existing formatter, not the Edge synthesis provider.
        upload_post_auto_upload=False,
        max_concurrent_tasks=1,
        max_queued_tasks=10,
    )
    config.azure.update(
        speech_auth_mode="entra",
        speech_endpoint=azure_endpoint(values["MPT_SPEECH_ENDPOINT"]),
        speech_resource_id=values["MPT_SPEECH_RESOURCE_ID"],
        speech_region=values["MPT_SPEECH_REGION"],
    )
