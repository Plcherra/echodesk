"""Voice pipeline: Deepgram STT -> Grok LLM -> TTS (Google Cloud).

Orchestrates turn-taking, debounce, and delegates calendar fast-path to intent_router
and tool execution to tool_dispatch.
"""

import asyncio
import logging
import re
import time
from collections import deque
from typing import Any, Callable, Awaitable, Optional

from config import settings
from voice.calendar_tools import CALENDAR_TOOLS
from voice.conversation_state import new_offered_slots_state, new_voice_session
from voice.deepgram_client import create_deepgram_live
from voice.deterministic_turns import resolve_deterministic_turn
from voice.grok_client import chat, chat_with_tools
from voice.intent_router import resolve_calendar_fast_path
from voice.pipeline_constants import (
    FAST_ACK_AVAILABILITY,
    FAST_ACK_BOOKING,
    MAX_HISTORY,
    MIN_CONFIDENCE,
    SHORT_PAUSE_MAX_WORDS,
    VOICE_OUTPUT_INSTRUCTIONS,
    voice_debounce_fallback_ms,
    voice_debounce_ms,
)
from voice.pipeline_templates import (
    deterministic_farewell_reply,
    deterministic_post_booking_reply,
    log_availability_guard,
    template_from_tool_result,
    unavailable_requested_time_reply,
)
from voice.pipeline_transcript import (
    asks_for_time_list,
    contains_clear_intent,
    extract_date_text_hint,
    extract_time_hint,
    is_farewell_courtesy_intent,
    is_incomplete_transcript,
    is_whitelisted_short_utterance,
    normalize_for_whitelist,
    passes_transcript_guard,
)
from voice.slot_selection import (
    is_new_availability_search_intent,
    recent_offered_slots_present,
    resolve_slot_selection,
)
from voice.tool_dispatch import (
    CALENDAR_TOOL_NAMES,
    PRE_TOOL_FILLER_PHRASE,
    make_calendar_tool_exec,
    normalize_tool_args,
)
from voice.tts_facade import generate_and_send_tts, warm_tts_phrase_cache
from voice.trace import mark_voice_event

logger = logging.getLogger(__name__)

__all__ = [
    "run_voice_pipeline",
    "normalize_tool_args",
    "make_calendar_tool_exec",
    "PRE_TOOL_FILLER_PHRASE",
    "CALENDAR_TOOL_NAMES",
]


def _deterministic_identity_reply(user_text: str, config: dict[str, Any]) -> str | None:
    norm = normalize_for_whitelist(user_text)
    if not norm:
        return None
    asks_name = (
        re.search(r"\bwhat(?:'s| is)\s+your\s+name\b", norm)
        or "who are you" in norm
        or "who am i speaking with" in norm
        or "who am i talking to" in norm
    )
    if not asks_name:
        return None
    identity = (config.get("assistant_identity") or "the receptionist").strip()
    if identity.lower() in {"receptionist", "the receptionist"}:
        return "I'm the receptionist. How can I help?"
    return f"I'm {identity}. How can I help?"


def _last_assistant_text(history: list[dict[str, Any]]) -> str:
    for msg in reversed(history):
        if msg.get("role") == "assistant":
            content = (msg.get("content") or "").strip()
            if content:
                return content
    return ""


async def _maybe_mark_consent_played(config: dict[str, Any]) -> None:
    on_consent_played = config.get("on_consent_played")
    if not callable(on_consent_played):
        return
    try:
        if asyncio.iscoroutinefunction(on_consent_played):
            await on_consent_played()
        else:
            on_consent_played()
    except Exception as e:
        logger.warning("[voice/stream] on_consent_played callback failed: %s", e)


async def _send_startup_audio(
    config: dict[str, Any],
    on_audio: Callable[[bytes], Awaitable[None]],
    on_error: Optional[Callable[[Exception], None]],
    tts_failure_logged: list[bool],
) -> None:
    """Play startup consent/greeting in the fastest legally-safe shape."""
    consent_phrase = (config.get("consent_phrase") or "").strip()
    greeting = (config.get("greeting") or "").strip()
    has_consent_callback = callable(config.get("on_consent_played"))

    if consent_phrase and greeting and has_consent_callback and settings.voice_combine_consent_and_greeting:
        startup_text = f"{consent_phrase.rstrip()} {greeting.lstrip()}"
        mark_voice_event(
            config.get("call_control_id"),
            "startup_audio_combined",
            chars=len(startup_text),
        )
        await generate_and_send_tts(
            startup_text,
            config,
            on_audio,
            on_error,
            _tts_failure_logged=tts_failure_logged,
            trace_label="startup_combined",
        )
        await _maybe_mark_consent_played(config)
        logger.info("[voice/stream] recording consent + greeting sent as combined startup audio")
        return

    if consent_phrase and has_consent_callback:
        await generate_and_send_tts(
            consent_phrase,
            config,
            on_audio,
            on_error,
            _tts_failure_logged=tts_failure_logged,
            trace_label="consent",
        )
        await _maybe_mark_consent_played(config)
        logger.info("[voice/stream] recording consent phrase sent; consent marked as played for this call")

    if greeting:
        await generate_and_send_tts(
            greeting,
            config,
            on_audio,
            on_error,
            _tts_failure_logged=tts_failure_logged,
            trace_label="greeting",
        )


async def run_voice_pipeline(
    config: dict[str, Any],
    on_audio: Callable[[bytes], Awaitable[None]],
    on_error: Optional[Callable[[Exception], None]] = None,
) -> tuple[Callable[[bytes], None], Callable[[], None]]:
    """
    Run the voice pipeline. Returns (send_audio, stop).
    send_audio(chunk) sends audio to Deepgram.
    stop() closes the pipeline.

    Turn-taking: Grok is only called when a user turn is complete (speech_final or UtteranceEnd).
    Debounce prevents duplicate triggers from tiny transcript updates.
    New caller speech cancels any pending or in-flight response.
    """
    system_content = (config.get("system_prompt") or "") + VOICE_OUTPUT_INSTRUCTIONS
    history: list[dict[str, Any]] = [
        {"role": "system", "content": system_content},
    ]
    if config.get("greeting"):
        history.append({"role": "assistant", "content": config["greeting"]})

    transcript_buffer: list[str] = []
    is_processing = False
    debounce_task: Optional[asyncio.Task] = None
    grok_task: Optional[asyncio.Task] = None
    turn_complete_transcript = ""
    turn_complete_confidence: Optional[float] = None
    last_rich_transcript = ""
    last_rich_transcript_ts = 0.0
    dg_ws: Any = None
    dg_task: Optional[asyncio.Task] = None
    tts_failure_logged: list[bool] = [False]
    tts_state: dict[str, int] = {"requests": 0, "chars": 0}
    config["tts_state"] = tts_state
    config.setdefault("tts_provider", (settings.tts_provider or "google").strip().lower())

    offered_slots_state = new_offered_slots_state()
    voice_session = new_voice_session()
    config["voice_session"] = voice_session
    pending_turn_queue: deque[tuple[str, Optional[float], int]] = deque()
    dispatch_commit_id_holder: dict[str, Optional[int]] = {"id": None}
    commit_seq = 0
    active_debounce_commit_id: list[Optional[int]] = [None]
    first_final_transcript_seen = False

    def _cancel_pending_response() -> None:
        """Cancel debounce and in-flight Grok. Call when new caller speech arrives."""
        nonlocal debounce_task, grok_task
        if debounce_task and not debounce_task.done():
            debounce_task.cancel()
            debounce_task = None
            logger.info(
                "[TURN_GUARD] dispatch_cancelled reason=new_speech_or_interim commit_id=%s",
                active_debounce_commit_id[0],
            )
            active_debounce_commit_id[0] = None
            logger.debug("[turn] Debounce cancelled (new speech)")
        if grok_task and not grok_task.done():
            grok_task.cancel()
            grok_task = None
            logger.debug("[turn] Grok task cancelled (new speech)")

    async def process_user_input() -> None:
        nonlocal is_processing, grok_task, turn_complete_transcript, turn_complete_confidence
        user_text = turn_complete_transcript
        confidence = turn_complete_confidence
        turn_complete_transcript = ""
        turn_complete_confidence = None

        cid = dispatch_commit_id_holder["id"]
        dispatch_commit_id_holder["id"] = None
        logger.info("[TURN_GUARD] dispatch_started path=process commit_id=%s", cid)
        mark_voice_event(config.get("call_control_id"), "dispatch_started", path="process", commit_id=cid)

        config["active_turn_commit_id"] = cid
        is_processing = True
        grok_task = None
        try:
            if user_text and is_farewell_courtesy_intent(user_text):
                fr = deterministic_farewell_reply(user_text)
                history.append({"role": "user", "content": user_text})
                history.append({"role": "assistant", "content": fr})
                logger.info(
                    "[turn] TTS started commit_id=%s response_len=%d (farewell)",
                    cid,
                    len(fr),
                )
                await generate_and_send_tts(
                    fr,
                    config,
                    on_audio,
                    on_error,
                    _tts_failure_logged=tts_failure_logged,
                    trace_label="farewell",
                )
                return

            identity_reply = _deterministic_identity_reply(user_text, config)
            if identity_reply:
                history.append({"role": "user", "content": user_text})
                history.append({"role": "assistant", "content": identity_reply})
                logger.info(
                    "[turn] TTS started commit_id=%s response_len=%d (identity_deterministic)",
                    cid,
                    len(identity_reply),
                )
                await generate_and_send_tts(
                    identity_reply,
                    config,
                    on_audio,
                    on_error,
                    _tts_failure_logged=tts_failure_logged,
                    trace_label="identity",
                )
                return

            use_calendar = bool(
                config.get("receptionist_id")
                and config.get("voice_server_api_key")
                and config.get("voice_server_base_url")
            )

            slot_pre_attempted = False
            last_slot_resolution = None
            explicit_datetime_request = bool(
                extract_date_text_hint(user_text or "") and extract_time_hint(user_text or "")
            )
            if (
                user_text
                and recent_offered_slots_present(offered_slots_state)
                and not explicit_datetime_request
                and not is_new_availability_search_intent(user_text)
            ):
                slot_pre_attempted = True
                logger.info(
                    "[CALL_DIAG] slot_selection_attempted commit_id=%s transcript=%s recent_slots_present=true",
                    cid,
                    user_text[:120],
                )
                last_slot_resolution = resolve_slot_selection(user_text, offered_slots_state)
                if last_slot_resolution.ok and last_slot_resolution.slot_iso:
                    logger.info(
                        "[CALL_DIAG] slot_selection_resolved commit_id=%s selected_start=%s source=%s",
                        cid,
                        last_slot_resolution.slot_iso[:64],
                        last_slot_resolution.source,
                    )
                elif last_slot_resolution.ambiguous:
                    logger.info(
                        "[CALL_DIAG] slot_selection_rejected commit_id=%s reason=ambiguous recent_slots_present=true",
                        cid,
                    )
                else:
                    logger.info(
                        "[CALL_DIAG] slot_selection_rejected commit_id=%s reason=no_match recent_slots_present=true",
                        cid,
                    )

            slot_booking_bypass_guard = bool(
                last_slot_resolution
                and last_slot_resolution.ok
                and last_slot_resolution.slot_iso
                and use_calendar
            )

            requested_time_hint = extract_time_hint(user_text or "")
            if (
                use_calendar
                and slot_pre_attempted
                and last_slot_resolution
                and not last_slot_resolution.ok
                and not last_slot_resolution.ambiguous
                and requested_time_hint
            ):
                reply = unavailable_requested_time_reply(requested_time_hint, offered_slots_state)
                history.append({"role": "user", "content": user_text})
                history.append({"role": "assistant", "content": reply})
                logger.info(
                    "[CALL_DIAG] unavailable_requested_time_reply commit_id=%s requested_time=%s",
                    cid,
                    requested_time_hint,
                )
                logger.info(
                    "[turn] TTS started commit_id=%s response_len=%d (unavailable_time)",
                    cid,
                    len(reply),
                )
                await generate_and_send_tts(
                    reply,
                    config,
                    on_audio,
                    on_error,
                    _tts_failure_logged=tts_failure_logged,
                    trace_label="unavailable_time",
                )
                return

            if not slot_booking_bypass_guard:
                if not user_text or not passes_transcript_guard(user_text):
                    detail = "empty_transcript" if not user_text else "failed_transcript_guard"
                    preview = repr((user_text or "")[:80])
                    logger.info(
                        "[TURN_GUARD] dispatch_skipped reason=guard_reject commit_id=%s detail=%s preview=%s",
                        cid,
                        detail,
                        preview,
                    )
                    return
                if confidence is not None and confidence < MIN_CONFIDENCE:
                    if not is_whitelisted_short_utterance(user_text):
                        logger.info("[TURN_GUARD] dispatch_skipped reason=low_confidence commit_id=%s", cid)
                        return
                    logger.info(
                        "[TURN_GUARD] low_confidence_whitelist_bypass transcript=%s confidence=%.2f",
                        user_text[:80],
                        confidence,
                    )

            vs = config.get("voice_session") or {}
            dpb = deterministic_post_booking_reply(user_text, vs if isinstance(vs, dict) else {})
            if dpb:
                history.append({"role": "user", "content": user_text})
                history.append({"role": "assistant", "content": dpb})
                logger.info(
                    "[turn] TTS started commit_id=%s response_len=%d (post_booking_deterministic)",
                    cid,
                    len(dpb),
                )
                await generate_and_send_tts(
                    dpb,
                    config,
                    on_audio,
                    on_error,
                    _tts_failure_logged=tts_failure_logged,
                    trace_label="post_booking",
                )
                return

            deterministic = resolve_deterministic_turn(
                user_text,
                offered_slots_state=offered_slots_state,
                use_calendar=use_calendar,
                slot_pre_attempted=slot_pre_attempted,
                last_slot_resolution=last_slot_resolution,
                last_assistant_text=_last_assistant_text(history),
            )
            if deterministic.reply:
                history.append({"role": "user", "content": user_text})
                history.append({"role": "assistant", "content": deterministic.reply})
                logger.info(
                    "[turn] TTS started commit_id=%s response_len=%d (deterministic_%s)",
                    cid,
                    len(deterministic.reply),
                    deterministic.reason,
                )
                mark_voice_event(
                    config.get("call_control_id"),
                    "deterministic_turn_reply",
                    commit_id=cid,
                    reason=deterministic.reason,
                )
                await generate_and_send_tts(
                    deterministic.reply,
                    config,
                    on_audio,
                    on_error,
                    _tts_failure_logged=tts_failure_logged,
                    trace_label=f"deterministic_{deterministic.reason}",
                )
                return

            logger.info("[turn] Grok task started transcript=%r", user_text[:80])
            t_turn_start = time.perf_counter()
            logger.info("[BOOKING_LATENCY] turn_start t=%.3f", t_turn_start)

            history.append({"role": "user", "content": user_text})
            if len(history) > MAX_HISTORY + 2:
                history[2 : 2 + len(history) - MAX_HISTORY - 2] = []

            if use_calendar:
                fast_tool_name = deterministic.tool_name
                fast_tool_args = deterministic.tool_args
                fast_date = deterministic.requested_date
                fast_time = deterministic.requested_time
                if not fast_tool_name:
                    fp = resolve_calendar_fast_path(
                        user_text,
                        offered_slots_state,
                        slot_pre_attempted=slot_pre_attempted,
                        last_slot_resolution=last_slot_resolution,
                    )
                    fast_tool_name = fp.fast_tool_name
                    fast_tool_args = fp.fast_tool_args
                    fast_date = fp.fast_date
                    fast_time = fp.fast_time

                if fast_tool_name:
                    pre_ack = FAST_ACK_BOOKING if fast_tool_name == "create_appointment" else FAST_ACK_AVAILABILITY
                    logger.info("[CALL_DIAG] pre_ack_sent text=%r", pre_ack)
                    logger.info(
                        "[turn] TTS started commit_id=%s response_len=%d (pre_ack)",
                        cid,
                        len(pre_ack),
                    )
                    await generate_and_send_tts(
                        pre_ack,
                        config,
                        on_audio,
                        on_error,
                        _tts_failure_logged=tts_failure_logged,
                        trace_label="pre_ack",
                    )

                prev_skip_pre_tool = bool(config.get("skip_pre_tool_speech"))
                if fast_tool_name:
                    config["skip_pre_tool_speech"] = True
                tool_exec = make_calendar_tool_exec(
                    config=config,
                    on_audio=on_audio,
                    on_error=on_error,
                    tts_failure_logged=tts_failure_logged,
                    offered_slots_state=offered_slots_state,
                )

                if fast_tool_name:
                    logger.info("[CALL_DIAG] tool_direct_dispatch tool=%s", fast_tool_name)
                    fast_result = await tool_exec(fast_tool_name, fast_tool_args)
                    templated = template_from_tool_result(
                        fast_tool_name,
                        fast_result,
                        requested_date=fast_date,
                        requested_time=fast_time,
                        voice_session=config.get("voice_session"),
                        list_exact_times=asks_for_time_list(user_text),
                    )
                    if templated:
                        logger.info("[CALL_DIAG] template_response_used type=%s", fast_tool_name)
                        history.append({"role": "assistant", "content": templated})
                        logger.info(
                            "[turn] TTS started commit_id=%s response_len=%d",
                            cid,
                            len(templated),
                        )
                        t_tts_start = time.perf_counter()
                        logger.info(
                            "[BOOKING_LATENCY] tts_start t=%.3f response_len=%d",
                            t_tts_start,
                            len(templated),
                        )
                        await generate_and_send_tts(
                            templated,
                            config,
                            on_audio,
                            on_error,
                            _tts_failure_logged=tts_failure_logged,
                            trace_label=f"template_{fast_tool_name}",
                        )
                        config["skip_pre_tool_speech"] = prev_skip_pre_tool
                        t_turn_end = time.perf_counter()
                        logger.info(
                            "[BOOKING_LATENCY] turn_end total_ms=%.0f tts_ms=%.0f fast_path=true",
                            (t_turn_end - t_turn_start) * 1000,
                            (t_turn_end - t_tts_start) * 1000,
                        )
                        return
                    logger.info(
                        "[CALL_DIAG] llm_fallback_used reason=template_unavailable tool=%s",
                        fast_tool_name,
                    )
                    config["skip_pre_tool_speech"] = prev_skip_pre_tool

                response = await chat_with_tools(
                    history,
                    CALENDAR_TOOLS,
                    tool_exec,
                    config["grok_api_key"],
                    trace_call_id=config.get("call_control_id"),
                    trace_commit_id=cid,
                )
            else:
                response = await chat(
                    history,
                    config["grok_api_key"],
                    trace_call_id=config.get("call_control_id"),
                    trace_commit_id=cid,
                )

            history.append({"role": "assistant", "content": response})
            if use_calendar and offered_slots_state:
                log_availability_guard(response, offered_slots_state)
            logger.info(
                "[turn] TTS started commit_id=%s response_len=%d",
                cid,
                len(response),
            )
            t_tts_start = time.perf_counter()
            logger.info("[BOOKING_LATENCY] tts_start t=%.3f response_len=%d", t_tts_start, len(response))
            await generate_and_send_tts(
                response, config, on_audio, on_error,
                _tts_failure_logged=tts_failure_logged,
                trace_label="llm_response",
            )
            t_turn_end = time.perf_counter()
            logger.info("[BOOKING_LATENCY] turn_end total_ms=%.0f tts_ms=%.0f", (t_turn_end - t_turn_start) * 1000, (t_turn_end - t_tts_start) * 1000)
        except asyncio.CancelledError:
            logger.debug("[turn] Grok task cancelled")
            raise
        except Exception as err:
            if on_error:
                on_error(err)
            apology = "I'm sorry, I didn't catch that. Could you repeat that?"
            logger.info(
                "[turn] TTS started commit_id=%s response_len=%d (error_apology)",
                cid,
                len(apology),
            )
            await generate_and_send_tts(
                apology,
                config,
                on_audio,
                on_error,
                _tts_failure_logged=tts_failure_logged,
                trace_label="error_apology",
            )
        finally:
            config.pop("active_turn_commit_id", None)
            is_processing = False
            if pending_turn_queue:
                t2, c2, cid2 = pending_turn_queue.popleft()
                turn_complete_transcript = t2
                turn_complete_confidence = c2
                dispatch_commit_id_holder["id"] = cid2
                logger.info("[TURN_GUARD] dispatch_started path=queued_flush commit_id=%s", cid2)
                mark_voice_event(config.get("call_control_id"), "dispatch_started", path="queued_flush", commit_id=cid2)
                grok_task = asyncio.create_task(process_user_input())

    def _schedule_trigger(alts: list, *, trigger_source: str) -> None:
        """Schedule Grok after debounce. Only one response per user turn."""
        nonlocal debounce_task, turn_complete_transcript, turn_complete_confidence, grok_task, commit_seq

        if debounce_task and not debounce_task.done():
            debounce_task.cancel()
            debounce_task = None

        full_transcript = " ".join(transcript_buffer).strip()
        confidence = alts[0].get("confidence") if alts else None

        logger.debug(
            "[turn] Turn end detected transcript=%r interim_buf_len=%d confidence=%s",
            full_transcript[:50] if full_transcript else "",
            len(transcript_buffer),
            confidence,
        )

        if not full_transcript:
            logger.debug("[turn] Trigger skipped: empty transcript")
            transcript_buffer.clear()
            return

        if is_incomplete_transcript(full_transcript) and not contains_clear_intent(full_transcript):
            logger.info("[TURN_GUARD] incomplete_transcript_wait transcript=%s", full_transcript[:80])
            return

        commit_reason = "default"
        commit_text = full_transcript
        is_short_whitelist = is_whitelisted_short_utterance(full_transcript)
        has_clear_intent = contains_clear_intent(full_transcript)
        has_farewell = is_farewell_courtesy_intent(full_transcript)

        # Prevent short trailing fragments ("hi", "hello") from overriding a richer
        # caller turn that was captured moments earlier.
        now_mono = time.monotonic()
        if is_short_whitelist and last_rich_transcript and (now_mono - last_rich_transcript_ts) <= 8.0:
            commit_text = last_rich_transcript
            commit_reason = "reuse_recent_rich_transcript"
        elif has_clear_intent:
            commit_reason = "clear_intent_final"
        elif has_farewell:
            commit_reason = "farewell_courtesy"
        elif is_short_whitelist:
            commit_reason = "short_whitelist_final"

        transcript_buffer.clear()

        commit_seq += 1
        commit_id = commit_seq
        logger.info(
            "[TURN_GUARD] commit_candidate reason=%s transcript=%s",
            commit_reason,
            commit_text[:120],
        )
        logger.info("[TURN_GUARD] commit_enqueued commit_id=%s", commit_id)
        mark_voice_event(
            config.get("call_control_id"),
            "commit_enqueued",
            commit_id=commit_id,
            reason=commit_reason,
            trigger_source=trigger_source,
            word_count=len(commit_text.lower().split()),
        )

        words = commit_text.lower().split()
        word_count = len(words)

        # Fail-open policy: final short-whitelist, clear-intent, or farewell dispatch immediately.
        if is_short_whitelist or has_clear_intent or has_farewell:
            turn_complete_transcript = commit_text
            turn_complete_confidence = confidence
            if not is_processing:
                dispatch_commit_id_holder["id"] = commit_id
                logger.info(
                    "[TURN_GUARD] dispatch_started path=immediate reason=%s commit_id=%s transcript=%s",
                    commit_reason,
                    commit_id,
                    commit_text[:120],
                )
                mark_voice_event(config.get("call_control_id"), "dispatch_started", path="immediate", commit_id=commit_id, reason=commit_reason)
                grok_task = asyncio.create_task(process_user_input())
            else:
                pending_turn_queue.append((commit_text, confidence, commit_id))
                logger.info(
                    "[TURN_GUARD] dispatch_skipped reason=queued_for_after_processing commit_id=%s transcript=%s",
                    commit_id,
                    commit_text[:120],
                )
            return

        if word_count <= SHORT_PAUSE_MAX_WORDS:
            debounce_ms = voice_debounce_fallback_ms()
            logger.info("[TURN_GUARD] short_utterance_fallback_trigger transcript=%s", commit_text[:80])
        else:
            debounce_ms = voice_debounce_ms()

        snap_text, snap_conf, snap_id = commit_text, confidence, commit_id

        def _on_debounce_done(t: asyncio.Task) -> None:
            nonlocal debounce_task, grok_task, turn_complete_transcript, turn_complete_confidence
            debounce_task = None
            active_debounce_commit_id[0] = None
            if t.cancelled():
                logger.info(
                    "[TURN_GUARD] dispatch_cancelled reason=debounce_task_cancelled commit_id=%s",
                    snap_id,
                )
                return
            turn_complete_transcript = snap_text
            turn_complete_confidence = snap_conf
            if not is_processing:
                dispatch_commit_id_holder["id"] = snap_id
                logger.info(
                    "[TURN_GUARD] dispatch_started path=debounce commit_id=%s debounce_ms=%s",
                    snap_id,
                    debounce_ms,
                )
                mark_voice_event(config.get("call_control_id"), "dispatch_started", path="debounce", commit_id=snap_id, debounce_ms=debounce_ms)
                grok_task = asyncio.create_task(process_user_input())
            else:
                pending_turn_queue.append((snap_text, snap_conf, snap_id))
                logger.info(
                    "[TURN_GUARD] dispatch_skipped reason=queued_after_debounce commit_id=%s",
                    snap_id,
                )

        active_debounce_commit_id[0] = commit_id
        debounce_task = asyncio.create_task(asyncio.sleep(debounce_ms / 1000.0))
        debounce_task.add_done_callback(_on_debounce_done)

    async def on_dg_message(msg: dict) -> None:
        nonlocal transcript_buffer, last_rich_transcript, last_rich_transcript_ts, first_final_transcript_seen

        msg_type = msg.get("type", "Results")

        if msg_type == "UtteranceEnd":
            last_word_end = msg.get("last_word_end")
            if last_word_end == -1:
                logger.debug("[turn] UtteranceEnd ignored (last_word_end=-1, duplicate)")
                return
            logger.debug(
                "[turn] UtteranceEnd received last_word_end=%.2f buffer=%r",
                last_word_end or 0,
                transcript_buffer,
            )
            alts = []
            if isinstance(msg.get("channel"), dict):
                alts = msg["channel"].get("alternatives") or []
            mark_voice_event(config.get("call_control_id"), "utterance_end", source="deepgram_utterance_end")
            _schedule_trigger(alts, trigger_source="utterance_end")
            return

        channel = msg.get("channel")
        if not isinstance(channel, dict):
            channel = {}
        alts = channel.get("alternatives") or []
        transcript = (alts[0].get("transcript") or "").strip() if alts else ""
        is_final = msg.get("is_final") is True
        speech_final = msg.get("speech_final") is True

        logger.debug(
            "[turn] Transcript received is_final=%s speech_final=%s transcript=%r",
            is_final,
            speech_final,
            transcript[:40] if transcript else "",
        )

        if transcript and not speech_final:
            _cancel_pending_response()

        if is_final and transcript:
            transcript_buffer.append(transcript)
            if first_final_transcript_seen:
                mark_voice_event(config.get("call_control_id"), "final_transcript", transcript_len=len(transcript))
            else:
                mark_voice_event(config.get("call_control_id"), "first_final_transcript", transcript_len=len(transcript))
                first_final_transcript_seen = True
            # Save richer final transcripts so short trailing utterances do not erase intent.
            if contains_clear_intent(transcript) or len((transcript or "").split()) >= 5:
                last_rich_transcript = transcript
                last_rich_transcript_ts = time.monotonic()
            if not speech_final and is_whitelisted_short_utterance(transcript):
                logger.info(
                    "[TURN_GUARD] final_short_utterance_trigger transcript=%s",
                    transcript[:80],
                )
                _schedule_trigger(alts, trigger_source="final_short_utterance")
                return

        if speech_final:
            logger.debug("[turn] speech_final=True, scheduling trigger")
            mark_voice_event(config.get("call_control_id"), "speech_final", source="deepgram_results")
            mark_voice_event(config.get("call_control_id"), "utterance_end", source="speech_final")
            _schedule_trigger(alts, trigger_source="speech_final")

    def on_dg_error(err: Exception) -> None:
        logger.error("Deepgram error: %s", err)
        mark_voice_event(config.get("call_control_id"), "deepgram_error", error=str(err))
        if on_error:
            on_error(err)

    dg_ws, dg_task = await create_deepgram_live(
        api_key=config["deepgram_api_key"],
        encoding="mulaw",
        sample_rate=8000,
        on_message=on_dg_message,
        on_error=on_dg_error,
    )
    mark_voice_event(config.get("call_control_id"), "deepgram_connected")

    await _send_startup_audio(config, on_audio, on_error, tts_failure_logged)
    if settings.tts_warm_common_phrases:
        asyncio.create_task(warm_tts_phrase_cache(config))

    def send_audio(chunk: bytes) -> None:
        if dg_ws:
            try:
                asyncio.create_task(dg_ws.send(chunk))
            except Exception:
                pass

    def stop() -> None:
        if debounce_task and not debounce_task.done():
            debounce_task.cancel()
        if grok_task and not grok_task.done():
            grok_task.cancel()
        if dg_task and not grok_task.done():
            dg_task.cancel()
        if dg_ws:
            asyncio.create_task(dg_ws.close())

    return send_audio, stop
