"""Pocket TTS hybrid: resolve, facade routing, clone consent."""

from __future__ import annotations

from typing import Any

import pytest

from config import settings
from voice import tts_facade
from voice.pocket_tts import PocketTtsError
from voice_presets import ResolvedTtsVoice, resolve_tts_voice


def test_resolve_preset_stays_google() -> None:
    voice = resolve_tts_voice("friendly_warm", None)
    assert voice.provider == "google"
    assert voice.google_voice_name == "en-US-Neural2-F"
    assert voice.voice_clone_id is None
    assert voice.pocket_voice is None


def test_resolve_clone_wins_when_path_set() -> None:
    voice = resolve_tts_voice(
        "professional_calm",
        None,
        voice_clone_id="clone-1",
        pocket_voice_path="/opt/echodesk/voices/u1/clone-1.safetensors",
    )
    assert voice.provider == "pocket"
    assert voice.voice_clone_id == "clone-1"
    assert voice.google_voice_name == "en-US-Neural2-C"


def test_resolve_clone_without_path_stays_google() -> None:
    voice = resolve_tts_voice(
        "professional_calm",
        None,
        voice_clone_id="clone-1",
        pocket_voice_path=None,
    )
    assert voice.provider == "google"
    assert voice.voice_clone_id is None


@pytest.mark.asyncio
async def test_facade_routes_clone_to_pocket(monkeypatch) -> None:
    called: dict[str, Any] = {}

    async def fake_pocket(text: str, voice: ResolvedTtsVoice) -> bytes:
        called["text"] = text
        called["path"] = voice.pocket_voice_path
        return b"\xff" * 2000

    async def fail_google(*_args, **_kwargs) -> bytes:
        raise AssertionError("Google must not run for a healthy Pocket clone")

    async def healthy() -> bool:
        return True

    monkeypatch.setattr(tts_facade, "_pocket_synthesize_to_mulaw", fake_pocket)
    monkeypatch.setattr(tts_facade, "_google_synthesize_to_mulaw", fail_google)
    monkeypatch.setattr(tts_facade, "pocket_enabled", lambda: True)
    monkeypatch.setattr(tts_facade, "_pocket_is_healthy", healthy)

    config = {
        "resolved_tts_voice": ResolvedTtsVoice(
            google_language_code="en-US",
            google_voice_name="en-US-Neural2-C",
            model_id=None,
            provider="pocket",
            voice_clone_id="clone-1",
            pocket_voice_path="/voices/u/c.safetensors",
        ),
        "tts_state": {"requests": 0, "chars": 0},
    }
    sent: list[bytes] = []

    async def on_audio(chunk: bytes) -> None:
        sent.append(chunk)

    await tts_facade.generate_and_send_tts("Hello there.", config, on_audio)
    assert called["path"] == "/voices/u/c.safetensors"
    assert sent


@pytest.mark.asyncio
async def test_facade_falls_back_to_google_on_pocket_failure(monkeypatch) -> None:
    async def boom(*_args, **_kwargs) -> bytes:
        raise PocketTtsError("down")

    async def fake_google(text: str, voice: ResolvedTtsVoice, *, use_backup_voice: bool = False) -> bytes:
        return b"g" * 1600

    async def healthy() -> bool:
        return True

    monkeypatch.setattr(tts_facade, "_pocket_synthesize_to_mulaw", boom)
    monkeypatch.setattr(tts_facade, "_google_synthesize_to_mulaw", fake_google)
    monkeypatch.setattr(tts_facade, "pocket_enabled", lambda: True)
    monkeypatch.setattr(tts_facade, "_pocket_is_healthy", healthy)

    config = {
        "resolved_tts_voice": ResolvedTtsVoice(
            google_language_code="en-US",
            google_voice_name="en-US-Neural2-C",
            model_id=None,
            provider="pocket",
            voice_clone_id="clone-1",
            pocket_voice_path="/voices/u/c.safetensors",
        ),
        "tts_state": {"requests": 0, "chars": 0},
    }
    sent: list[bytes] = []

    async def on_audio(chunk: bytes) -> None:
        sent.append(chunk)

    await tts_facade.generate_and_send_tts("Hello there.", config, on_audio)
    assert sent and sent[0].startswith(b"g")


def test_voice_clone_consent_helper() -> None:
    from api.mobile.voice_clones import _truthy_consent

    assert _truthy_consent("true")
    assert _truthy_consent(True)
    assert not _truthy_consent("no")
    assert not _truthy_consent(None)


def test_friendly_export_error_hides_sidecar_json() -> None:
    from api.mobile.voice_clones import _friendly_export_error

    err = PocketTtsError('export-voice 502: {"detail":"export_voice_failed"}', status_code=502)
    out = _friendly_export_error(err)
    assert "502" not in out
    assert "export_voice_failed" not in out
    assert "clone" in out.lower()


def test_pocket_disabled_by_default() -> None:
    assert settings.pocket_tts_enabled is False
    assert (settings.tts_provider or "google").lower() == "google"
