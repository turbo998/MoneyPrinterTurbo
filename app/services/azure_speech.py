"""One-shot keyless Speech synthesis with real SDK word boundaries."""

from datetime import timedelta

from app.services.azure_auth import azure_endpoint, credential


def duration_ticks(value) -> int:
    if isinstance(value, timedelta):
        return round(value.total_seconds() * 10_000_000)
    if isinstance(value, int):
        return value
    raise ValueError("Unsupported Speech boundary duration")


def synthesize(
    text: str, voice_name: str, voice_file: str, rate: float, settings: dict
):
    import azure.cognitiveservices.speech as sdk
    from edge_tts import SubMaker

    from app.services.voice import _build_azure_v2_ssml, ensure_legacy_submaker_fields

    endpoint = azure_endpoint(settings["speech_endpoint"])
    resource_id = settings["speech_resource_id"]
    if not resource_id.startswith("/subscriptions/"):
        raise ValueError("speech_resource_id must be an Azure resource ID")
    speech_config = sdk.SpeechConfig(
        endpoint=endpoint,
        token_credential=credential(),
    )
    speech_config.speech_synthesis_voice_name = voice_name
    speech_config.set_property(
        sdk.PropertyId.SpeechServiceResponse_RequestWordBoundary, "true"
    )
    speech_config.set_speech_synthesis_output_format(
        sdk.SpeechSynthesisOutputFormat.Audio48Khz192KBitRateMonoMp3
    )
    output = sdk.audio.AudioOutputConfig(filename=voice_file)
    synthesizer = sdk.SpeechSynthesizer(
        speech_config=speech_config, audio_config=output
    )
    maker = ensure_legacy_submaker_fields(SubMaker())

    def boundary(evt):
        if evt.boundary_type == sdk.SpeechSynthesisBoundaryType.Word:
            start = int(evt.audio_offset)
            end = start + duration_ticks(evt.duration)
            if end > start and evt.text:
                maker.subs.append(evt.text)
                maker.offset.append((start, end))

    synthesizer.synthesis_word_boundary.connect(boundary)
    result = synthesizer.speak_ssml_async(
        _build_azure_v2_ssml(text, voice_name, rate)
    ).get()
    if result.reason != sdk.ResultReason.SynthesizingAudioCompleted:
        # No retry: cancellation can follow an accepted, billable request.
        raise RuntimeError(
            f"Azure Speech did not complete (result_id={result.result_id})"
        )
    if not maker.offset:
        raise RuntimeError(
            "Speech returned audio without word boundaries. This voice cannot produce "
            "aligned subtitles; select a verified Neural voice. Audio was not resynthesized."
        )
    return maker
