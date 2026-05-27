from __future__ import annotations

from typing import Any

import pytest

from config import settings
from voice import pipeline


@pytest.mark.asyncio
async def test_startup_audio_combines_consent_and_greeting(monkeypatch):
    calls: list[dict[str, Any]] = []
    consent_marked = {"value": False}

    async def fake_tts(text: str, config: dict, on_audio, on_error=None, **kwargs):
        calls.append({"text": text, "label": kwargs.get("trace_label")})

    async def on_consent_played():
        consent_marked["value"] = True

    monkeypatch.setattr(settings, "voice_combine_consent_and_greeting", True)
    monkeypatch.setattr(pipeline, "generate_and_send_tts", fake_tts)

    await pipeline._send_startup_audio(
        {
            "call_control_id": "call-1",
            "consent_phrase": "This call may be recorded.",
            "greeting": "Thanks for calling, this is Eve. How can I help?",
            "on_consent_played": on_consent_played,
        },
        on_audio=lambda _chunk: None,
        on_error=None,
        tts_failure_logged=[False],
    )

    assert len(calls) == 1
    assert calls[0]["label"] == "startup_combined"
    assert calls[0]["text"] == "This call may be recorded. Thanks for calling, this is Eve. How can I help?"
    assert consent_marked["value"] is True


@pytest.mark.asyncio
async def test_startup_audio_can_keep_consent_and_greeting_separate(monkeypatch):
    calls: list[dict[str, Any]] = []
    consent_marked = {"value": False}

    async def fake_tts(text: str, config: dict, on_audio, on_error=None, **kwargs):
        calls.append({"text": text, "label": kwargs.get("trace_label")})

    def on_consent_played():
        consent_marked["value"] = True

    monkeypatch.setattr(settings, "voice_combine_consent_and_greeting", False)
    monkeypatch.setattr(pipeline, "generate_and_send_tts", fake_tts)

    await pipeline._send_startup_audio(
        {
            "consent_phrase": "This call may be recorded.",
            "greeting": "Hello.",
            "on_consent_played": on_consent_played,
        },
        on_audio=lambda _chunk: None,
        on_error=None,
        tts_failure_logged=[False],
    )

    assert [c["label"] for c in calls] == ["consent", "greeting"]
    assert [c["text"] for c in calls] == ["This call may be recorded.", "Hello."]
    assert consent_marked["value"] is True


def test_phase_2_tts_cache_defaults_enabled():
    assert settings.tts_cache_backend == "filesystem"
    assert settings.tts_cache_filesystem_dir
