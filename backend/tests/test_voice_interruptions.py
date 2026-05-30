from __future__ import annotations

import asyncio
from typing import Any

import pytest

from config import settings
from voice import pipeline, tts_facade
from voice_presets import ResolvedTtsVoice


@pytest.mark.asyncio
async def test_tts_chunk_send_stops_after_interruption(monkeypatch) -> None:
    async def fake_synthesize(text: str, voice: ResolvedTtsVoice, *, use_backup_voice: bool = False) -> bytes:
        return b"x" * 3000

    monkeypatch.setattr(settings, "tts_mulaw_chunk_bytes", 1000)
    monkeypatch.setattr(tts_facade, "_google_synthesize_to_mulaw", fake_synthesize)

    config: dict[str, Any] = {
        "resolved_tts_voice": ResolvedTtsVoice(
            google_language_code="en-US",
            google_voice_name="en-US-Neural2-C",
            model_id=None,
        ),
        "tts_state": {"requests": 0, "chars": 0},
    }
    sent: list[bytes] = []

    async def on_audio(chunk: bytes) -> None:
        sent.append(chunk)
        tts_facade.interrupt_tts_playback(config, reason="test_interrupt")

    await tts_facade.generate_and_send_tts("This is a long response.", config, on_audio)

    assert len(sent) == 1
    assert config["tts_playback_state"]["status"] == "interrupted"


@pytest.mark.asyncio
async def test_pipeline_stop_handles_missing_grok_task(monkeypatch) -> None:
    class FakeDeepgramWs:
        def __init__(self) -> None:
            self.closed = False

        async def send(self, _chunk: bytes) -> None:
            return None

        async def close(self) -> None:
            self.closed = True

    fake_ws = FakeDeepgramWs()
    receive_task = asyncio.create_task(asyncio.sleep(60))

    async def fake_create_deepgram_live(**_kwargs):
        return fake_ws, receive_task

    async def fake_startup(*_args, **_kwargs):
        return None

    monkeypatch.setattr(pipeline, "create_deepgram_live", fake_create_deepgram_live)
    monkeypatch.setattr(pipeline, "_send_startup_audio", fake_startup)
    monkeypatch.setattr(settings, "tts_warm_common_phrases", False)

    _send_audio, stop = await pipeline.run_voice_pipeline(
        {
            "deepgram_api_key": "dg",
            "grok_api_key": "grok",
            "system_prompt": "sys",
            "resolved_tts_voice": ResolvedTtsVoice(
                google_language_code="en-US",
                google_voice_name="en-US-Neural2-C",
                model_id=None,
            ),
        },
        on_audio=lambda _chunk: None,
    )

    stop()
    await asyncio.sleep(0)

    assert receive_task.cancelled()
    assert fake_ws.closed is True
