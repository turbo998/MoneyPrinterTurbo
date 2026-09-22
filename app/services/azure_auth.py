"""Shared, refreshable Entra credentials. Never persist access tokens."""

import os
from functools import lru_cache
from urllib.parse import urlsplit


@lru_cache(maxsize=1)
def credential():
    from azure.identity import DefaultAzureCredential, ManagedIdentityCredential

    client_id = os.getenv("AZURE_CLIENT_ID")
    if os.getenv("IDENTITY_ENDPOINT"):
        return ManagedIdentityCredential(client_id=client_id)
    return DefaultAzureCredential(
        managed_identity_client_id=client_id,
        exclude_interactive_browser_credential=True,
    )


@lru_cache(maxsize=1)
def token_provider():
    from azure.identity import get_bearer_token_provider

    return get_bearer_token_provider(
        credential(), "https://cognitiveservices.azure.com/.default"
    )


def azure_endpoint(endpoint: str, *, v1: bool = False) -> str:
    """Do not send a cognitive-services bearer token to arbitrary gateways."""
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or not parsed.hostname.endswith(
            (
                ".openai.azure.com",
                ".cognitiveservices.azure.com",
                ".services.ai.azure.com",
            )
        )
        or parsed.username
        or parsed.password
        or parsed.port not in (None, 443)
        or parsed.query
        or parsed.fragment
        or parsed.path.rstrip("/") not in ("", "/openai/v1")
    ):
        raise ValueError("Entra requires a trusted Azure HTTPS resource endpoint")
    root = f"https://{parsed.hostname}"
    return f"{root}/openai/v1/" if v1 else root
