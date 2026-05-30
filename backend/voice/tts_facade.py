"""TTS provider facade: Google Cloud TTS + cache + limits."""

from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Optional

from config import settings
from voice import tts_chars
from voice.tts_sanitizer import sanitize_for_tts
from voice.tts_pronunciation import normalize_pronunciation_for_tts
from voice.google_tts import (
    GoogleTtsSynthesizeOptions,
    assert_voice_allowed,
    synthesize_text_with_retry,
)
from voice.tts_cache import build_cache_key, create_tts_cache
from voice.trace import mark_voice_event
from voice_presets import ResolvedTtsVoice, google_voice_allowlist

logger = logging.getLogger(__name__)

_cache = None

COMMON_TTS_CACHE_WARM_PHRASES: tuple[str, ...] = (
    "Checking now.",
    "Got it. Booking now.",
    "One sec.",
    "Which day should I check?",
    "What day and time should I book it for?",
    "That time is no longer available. Want me to check another time?",
    "I'm having trouble reaching the calendar right now. Could you try again in a moment?",
)


def _playback_state(config: dict[str, Any]) -> dict[str, Any]:
    return config.setdefault(
        "tts_playback_state",
        {
            "utterance_seq": 0,
            "active_utterance_id": None,
            "status": "idle",
            "interrupted_utterance_id": None,
        },
    )


def begin_tts_utterance(config: dict[str, Any], *, label: str | None = None) -> int:
    """Start a cancellable assistant audio utterance and return its id."""
    state = _playback_state(config)
    state["utterance_seq"] = int(state.get("utterance_seq") or 0) + 1
    utterance_id = int(state["utterance_seq"])
    state["active_utterance_id"] = utterance_id
    state["interrupted_utterance_id"] = None
    state["status"] = "synthesizing"
    state["label"] = label
    return utterance_id


def mark_tts_sending(config: dict[str, Any], utterance_id: int) -> bool:
    state = _playback_state(config)
    if state.get("active_utterance_id") != utterance_id or state.get("interrupted_utterance_id") == utterance_id:
        return False
    state["status"] = "sending"
    return True


def finish_tts_utterance(config: dict[str, Any], utterance_id: int) -> None:
    state = _playback_state(config)
    if state.get("active_utterance_id") == utterance_id:
        state["status"] = "idle"
        state["active_utterance_id"] = None


def interrupt_tts_playback(config: dict[str, Any], *, reason: str = "caller_speech") -> bool:
    """Mark current assistant audio interrupted. Returns True if an utterance was active."""
    state = _playback_state(config)
    active = state.get("active_utterance_id")
    if active is None or state.get("status") in {"idle", "interrupted"}:
        return False
    state["interrupted_utterance_id"] = active
    state["status"] = "interrupted"
    state["interrupt_reason"] = reason
    mark_voice_event(
        config.get("call_control_id"),
        "assistant_audio_interrupted",
        commit_id=config.get("active_turn_commit_id"),
        utterance_id=active,
        reason=reason,
    )
    return True


def is_tts_utterance_interrupted(config: dict[str, Any], utterance_id: int) -> bool:
    state = _playback_state(config)
    return (
        state.get("active_utterance_id") != utterance_id
        or state.get("interrupted_utterance_id") == utterance_id
        or state.get("status") == "interrupted"
    )


def _get_cache():
    global _cache
    if _cache is None:
        _cache = create_tts_cache(
            backend=settings.tts_cache_backend,
            ttl_seconds=settings.tts_cache_ttl_seconds,
            memory_max_entries=settings.tts_cache_memory_max_entries,
            filesystem_dir=settings.tts_cache_filesystem_dir,
            redis_url=settings.tts_cache_redis_url,
            gcs_bucket=settings.tts_cache_gcs_bucket,
            gcs_prefix=settings.tts_cache_gcs_prefix,
        )
    return _cache


_daily_lock = asyncio.Lock()
_daily_utc_date: str | None = None
_daily_char_total: int = 0


async def _reserve_daily_chars(n: int, cap: int) -> bool:
    """Return True if n chars can be billed today (or cap disabled)."""
    global _daily_utc_date, _daily_char_total
    if cap <= 0:
        return True
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    async with _daily_lock:
        if _daily_utc_date != today:
            _daily_utc_date = today
            _daily_char_total = 0
        if _daily_char_total + n > cap:
            logger.error(
                "[TTS] daily character cap exceeded cap=%s used=%s requested=%s",
                cap,
                _daily_char_total,
                n,
            )
            return False
        _daily_char_total += n
        return True


def _truncate_text(text: str, max_chars: int) -> str:
    t = text or ""
    if len(t) <= max_chars:
        return t
    if max_chars <= 3:
        return t[:max_chars]
    return t[: max_chars - 3].rstrip() + "..."


def _prepare_text_for_tts(text: str) -> str:
    text = sanitize_for_tts(text)
    text = normalize_pronunciation_for_tts(text)
    return (text or "").strip()


async def _send_mulaw_chunks(
    audio: bytes,
    on_audio: Callable[[bytes], Awaitable[None]],
    chunk_bytes: int,
    *,
    config: dict[str, Any] | None = None,
    utterance_id: int | None = None,
    call_control_id: str | None = None,
    commit_id: int | None = None,
    label: str | None = None,
    request_index: int | None = None,
) -> None:
    if chunk_bytes <= 0:
        chunk_bytes = 1600
    t_chunk_start = time.perf_counter()
    chunks_sent = 0
    mark_voice_event(
        call_control_id,
        "assistant_audio_start",
        commit_id=commit_id,
        label=label,
        request_index=request_index,
        audio_bytes=len(audio),
    )
    for i in range(0, len(audio), chunk_bytes):
        if config is not None and utterance_id is not None and is_tts_utterance_interrupted(config, utterance_id):
            logger.info(
                "[TTS] chunk_send_interrupted utterance_id=%s chunks_sent=%s",
                utterance_id,
                chunks_sent,
            )
            mark_voice_event(
                call_control_id,
                "tts_chunk_send_interrupted",
                commit_id=commit_id,
                label=label,
                request_index=request_index,
                utterance_id=utterance_id,
                chunks_sent=chunks_sent,
            )
            return
        await on_audio(audio[i : i + chunk_bytes])
        chunks_sent += 1
    t_chunk_end = time.perf_counter()
    logger.info("[BOOKING_LATENCY] tts_chunks_sent chunks=%s duration_ms=%.0f", chunks_sent, (t_chunk_end - t_chunk_start) * 1000)
    mark_voice_event(
        call_control_id,
        "tts_media_chunks_sent",
        commit_id=commit_id,
        label=label,
        request_index=request_index,
        chunks=chunks_sent,
        duration_ms=int((t_chunk_end - t_chunk_start) * 1000),
    )


async def _google_synthesize_to_mulaw(
    text: str,
    voice: ResolvedTtsVoice,
    *,
    use_backup_voice: bool = False,
) -> bytes:
    allowlist = google_voice_allowlist()
    vname = settings.google_tts_backup_voice_name if use_backup_voice else voice.google_voice_name
    assert_voice_allowed(
        vname,
        allowlist=allowlist,
        allow_premium_tiers=settings.google_tts_allow_premium_tiers,
    )
    lang = voice.google_language_code
    opts = GoogleTtsSynthesizeOptions(
        language_code=lang,
        voice_name=vname,
        speaking_rate=settings.google_tts_speaking_rate,
        pitch=settings.google_tts_pitch,
        audio_encoding="MULAW",
        sample_rate_hertz=8000,
    )
    norm = tts_chars.normalize_text_for_cache_key(text)
    key = build_cache_key(
        voice_name=vname,
        language_code=lang,
        normalized_text=norm,
        speaking_rate=settings.google_tts_speaking_rate,
        pitch=settings.google_tts_pitch,
        audio_encoding="MULAW",
        sample_rate_hertz=8000,
    )
    cache = _get_cache()
    hit = await cache.get(key)
    if hit is not None:
        logger.info(
            "[TTS] cache_hit=true provider=google key_prefix=%s chars=%s",
            key[:16],
            len(text),
        )
        return hit
    t_synth_start = time.perf_counter()
    logger.info("[BOOKING_LATENCY] tts_synthesis_start chars=%s t=%.3f", len(text), t_synth_start)
    audio = await synthesize_text_with_retry(
        text,
        opts,
        max_retries=settings.tts_google_max_retries,
        base_seconds=settings.tts_google_retry_base_seconds,
        max_seconds=settings.tts_google_retry_max_seconds,
    )
    t_synth_end = time.perf_counter()
    logger.info("[BOOKING_LATENCY] tts_synthesis_end duration_ms=%.0f bytes=%s", (t_synth_end - t_synth_start) * 1000, len(audio))
    await cache.put(key, audio)
    return audio


def _billable_chars_plain(text: str) -> int:
    return tts_chars.plain_text_billable_chars(text)


async def generate_and_send_tts(
    text: str,
    config: dict[str, Any],
    on_audio: Callable[[bytes], Awaitable[None]],
    on_error: Optional[Callable[[Exception], None]] = None,
    is_fallback: bool = False,
    _tts_failure_logged: Optional[list[bool]] = None,
    trace_label: str | None = None,
) -> None:
    """Generate TTS and send via callback (Google Cloud TTS + chunking)."""
    if not text or not text.strip():
        return
    text = _prepare_text_for_tts(text)
    if not text or not text.strip():
        return
    tts_logged = _tts_failure_logged if _tts_failure_logged is not None else [False]
    tts_state: dict[str, int] = config.setdefault("tts_state", {"requests": 0, "chars": 0})

    max_req = settings.tts_max_requests_per_call
    if tts_state["requests"] >= max_req:
        logger.error("[TTS] max requests per call exceeded max=%s", max_req)
        return

    max_chars = settings.tts_max_chars_per_utterance
    use_text = _truncate_text(text.strip(), max_chars)
    billable = _billable_chars_plain(use_text)
    cpm = settings.tts_chars_per_minute_estimate
    est_min = tts_chars.estimated_speech_minutes(billable, cpm)

    daily_cap = settings.tts_daily_char_cap
    if not await _reserve_daily_chars(billable, daily_cap):
        logger.error("[TTS] daily character cap reached; skipping utterance")
        return

    tts_state["requests"] = tts_state.get("requests", 0) + 1
    tts_state["chars"] = tts_state.get("chars", 0) + billable
    request_index = tts_state["requests"]
    call_control_id = config.get("call_control_id")
    commit_id = config.get("active_turn_commit_id")
    label = trace_label or ("turn" if commit_id is not None else "system")

    logger.info(
        "[TTS] utterance provider=google chars=%s chars_call_total=%s est_minutes=%.3f tts_request_index=%s",
        billable,
        tts_state["chars"],
        est_min,
        request_index,
    )
    mark_voice_event(
        call_control_id,
        "tts_request_start",
        commit_id=commit_id,
        label=label,
        request_index=request_index,
        chars=billable,
        fallback=is_fallback,
    )

    voice: ResolvedTtsVoice | None = config.get("resolved_tts_voice")
    if voice is None:
        logger.error("[TTS] resolved_tts_voice missing")
        mark_voice_event(
            call_control_id,
            "tts_request_skipped",
            commit_id=commit_id,
            label=label,
            request_index=request_index,
            reason="missing_voice",
        )
        return

    utterance_id = begin_tts_utterance(config, label=label)
    try:
        mark_voice_event(
            call_control_id,
            "tts_synthesis_start",
            commit_id=commit_id,
            label=label,
            request_index=request_index,
            voice=voice.google_voice_name,
            backup=False,
            utterance_id=utterance_id,
        )
        audio = await _google_synthesize_to_mulaw(use_text, voice, use_backup_voice=False)
        if not mark_tts_sending(config, utterance_id):
            logger.info("[TTS] utterance_interrupted_before_send utterance_id=%s", utterance_id)
            mark_voice_event(
                call_control_id,
                "tts_interrupted_before_send",
                commit_id=commit_id,
                label=label,
                request_index=request_index,
                utterance_id=utterance_id,
            )
            return
        mark_voice_event(
            call_control_id,
            "tts_synthesis_end",
            commit_id=commit_id,
            label=label,
            request_index=request_index,
            audio_bytes=len(audio),
            backup=False,
            utterance_id=utterance_id,
        )
        await _send_mulaw_chunks(
            audio,
            on_audio,
            settings.tts_mulaw_chunk_bytes,
            config=config,
            utterance_id=utterance_id,
            call_control_id=call_control_id,
            commit_id=commit_id,
            label=label,
            request_index=request_index,
        )
        if not is_tts_utterance_interrupted(config, utterance_id):
            finish_tts_utterance(config, utterance_id)
    except Exception as err:
        logger.exception("[TTS] Google primary voice failed: %s", err)
        mark_voice_event(
            call_control_id,
            "tts_primary_failed",
            commit_id=commit_id,
            label=label,
            request_index=request_index,
            error=str(err),
        )
        try:
            backup_utterance_id = begin_tts_utterance(config, label=label)
            mark_voice_event(
                call_control_id,
                "tts_synthesis_start",
                commit_id=commit_id,
                label=label,
                request_index=request_index,
                voice=settings.google_tts_backup_voice_name,
                backup=True,
                utterance_id=backup_utterance_id,
            )
            audio = await _google_synthesize_to_mulaw(use_text, voice, use_backup_voice=True)
            if not mark_tts_sending(config, backup_utterance_id):
                logger.info("[TTS] backup_utterance_interrupted_before_send utterance_id=%s", backup_utterance_id)
                return
            mark_voice_event(
                call_control_id,
                "tts_synthesis_end",
                commit_id=commit_id,
                label=label,
                request_index=request_index,
                audio_bytes=len(audio),
                backup=True,
                utterance_id=backup_utterance_id,
            )
            await _send_mulaw_chunks(
                audio,
                on_audio,
                settings.tts_mulaw_chunk_bytes,
                config=config,
                utterance_id=backup_utterance_id,
                call_control_id=call_control_id,
                commit_id=commit_id,
                label=label,
                request_index=request_index,
            )
            if not is_tts_utterance_interrupted(config, backup_utterance_id):
                finish_tts_utterance(config, backup_utterance_id)
        except Exception as err2:
            logger.exception("[TTS] Google backup voice failed: %s", err2)
            mark_voice_event(
                call_control_id,
                "tts_backup_failed",
                commit_id=commit_id,
                label=label,
                request_index=request_index,
                error=str(err2),
            )
            if on_error:
                on_error(err2)
            if not is_fallback:
                await generate_and_send_tts(
                    "I'm sorry, I'm having trouble. Please try again.",
                    config,
                    on_audio,
                    on_error,
                    is_fallback=True,
                    _tts_failure_logged=tts_logged,
                    trace_label="tts_fallback",
                )


async def warm_tts_phrase_cache(config: dict[str, Any], phrases: tuple[str, ...] | None = None) -> int:
    """Best-effort warmup for frequent short spoken phrases."""
    if (settings.tts_cache_backend or "none").strip().lower() == "none":
        return 0
    voice: ResolvedTtsVoice | None = config.get("resolved_tts_voice")
    if voice is None:
        return 0
    warmed = 0
    for phrase in phrases or COMMON_TTS_CACHE_WARM_PHRASES:
        prepared = _prepare_text_for_tts(phrase)
        if not prepared:
            continue
        try:
            await _google_synthesize_to_mulaw(prepared, voice, use_backup_voice=False)
            warmed += 1
        except Exception as err:
            logger.warning("[TTS] common phrase warmup failed phrase=%r error=%s", phrase[:40], err)
    if warmed:
        logger.info("[TTS] common phrase cache warmup complete count=%s", warmed)
    return warmed


async def google_preview_mp3(text: str, voice: ResolvedTtsVoice) -> bytes:
    """MP3 preview bytes for mobile voice preset (Google provider)."""
    allowlist = google_voice_allowlist()
    assert_voice_allowed(
        voice.google_voice_name,
        allowlist=allowlist,
        allow_premium_tiers=settings.google_tts_allow_premium_tiers,
    )
    opts = GoogleTtsSynthesizeOptions(
        language_code=voice.google_language_code,
        voice_name=voice.google_voice_name,
        speaking_rate=settings.google_tts_speaking_rate,
        pitch=settings.google_tts_pitch,
        audio_encoding="MP3",
        sample_rate_hertz=settings.google_tts_preview_sample_rate_hertz,
    )
    text = _prepare_text_for_tts(text)
    return await synthesize_text_with_retry(
        text,
        opts,
        max_retries=settings.tts_google_max_retries,
        base_seconds=settings.tts_google_retry_base_seconds,
        max_seconds=settings.tts_google_retry_max_seconds,
    )
