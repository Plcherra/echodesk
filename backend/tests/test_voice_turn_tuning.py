from config import settings
from voice.deepgram_client import build_deepgram_live_params
from voice.pipeline_constants import voice_debounce_fallback_ms, voice_debounce_ms


def test_deepgram_live_params_are_env_tunable(monkeypatch):
    monkeypatch.setattr(settings, "deepgram_endpointing_ms", 150)
    monkeypatch.setattr(settings, "deepgram_utterance_end_ms", 700)

    params = build_deepgram_live_params()

    assert params["endpointing"] == "150"
    assert params["utterance_end_ms"] == "700"
    assert params["interim_results"] == "true"
    assert params["vad_events"] == "true"


def test_deepgram_live_params_are_capped(monkeypatch):
    monkeypatch.setattr(settings, "deepgram_endpointing_ms", 10_000)
    monkeypatch.setattr(settings, "deepgram_utterance_end_ms", 10)

    params = build_deepgram_live_params()

    assert params["endpointing"] == "1000"
    assert params["utterance_end_ms"] == "300"


def test_voice_debounce_settings_are_tunable_and_capped(monkeypatch):
    monkeypatch.setattr(settings, "voice_debounce_ms", 600)
    monkeypatch.setattr(settings, "voice_debounce_fallback_ms", 350)
    assert voice_debounce_ms() == 600
    assert voice_debounce_fallback_ms() == 350

    monkeypatch.setattr(settings, "voice_debounce_ms", 10_000)
    monkeypatch.setattr(settings, "voice_debounce_fallback_ms", 10)
    assert voice_debounce_ms() == 2000
    assert voice_debounce_fallback_ms() == 150
