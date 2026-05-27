"""Calendar tool execution: normalization, dedupe, pre-tool filler TTS, voice API calls."""

from __future__ import annotations

import json
import logging
import time
from typing import Any, Awaitable, Callable, Optional

from voice.calendar_tools import call_calendar_tool
from voice.tts_facade import generate_and_send_tts
from voice.trace import mark_voice_event

logger = logging.getLogger(__name__)

CALENDAR_TOOL_NAMES = ("check_availability", "create_appointment", "reschedule_appointment")
PRE_TOOL_FILLER_PHRASE = "One sec."


def normalize_tool_args(args: dict) -> dict:
    """Normalize tool args for stable caching/logging keys."""
    normalized: dict = {}
    for k, v in (args or {}).items():
        if v is None:
            continue
        if k == "duration_minutes" and isinstance(v, str):
            try:
                normalized[k] = int(v) or 30
            except (ValueError, TypeError):
                normalized[k] = 30
        elif k == "price_cents" and v is not None:
            try:
                normalized[k] = int(v)
            except (TypeError, ValueError):
                continue
        elif k == "attendees" and isinstance(v, list):
            normalized[k] = [x for x in v if isinstance(x, str)]
        else:
            normalized[k] = v
    return normalized


def make_calendar_tool_exec(
    *,
    config: dict[str, Any],
    on_audio: Callable[[bytes], Awaitable[None]],
    on_error: Optional[Callable[[Exception], None]],
    tts_failure_logged: list[bool],
    offered_slots_state: dict[str, Any],
) -> Callable[[str, dict], Awaitable[str]]:
    """
    Create a per-turn tool_exec coroutine that:
    - speaks a short filler phrase once per turn before first calendar tool call
    - dedupes identical calendar tool calls within the turn (tool name + normalized args)
    - calls the voice calendar API with normalized args
    """
    pre_tool_spoken_this_turn = False
    skip_pre_tool_speech = bool(config.get("skip_pre_tool_speech"))
    tool_cache: dict[tuple[str, str], str] = {}

    base_url = config.get("voice_server_base_url")
    api_key = config.get("voice_server_api_key")
    rec_id = config.get("receptionist_id")
    caller_phone = (config.get("caller_phone") or "").strip() or None
    call_control_id = (config.get("call_control_id") or "").strip() or None

    async def _maybe_pre_tool_speech(tool_name: str) -> None:
        nonlocal pre_tool_spoken_this_turn
        if skip_pre_tool_speech:
            return
        if pre_tool_spoken_this_turn:
            return
        if tool_name not in CALENDAR_TOOL_NAMES:
            return
        pre_tool_spoken_this_turn = True
        t_pre = time.perf_counter()
        logger.info("[BOOKING_LATENCY] pre_tool_speech_start tool=%s t=%.3f", tool_name, t_pre)
        phrase = PRE_TOOL_FILLER_PHRASE
        logger.info("[CALL_DIAG] pre_tool_speech_sent tool=%s text=%r", tool_name, phrase)
        ac = config.get("active_turn_commit_id")
        logger.info(
            "[turn] TTS started commit_id=%s response_len=%d (pre_tool_filler)",
            ac,
            len(phrase),
        )
        await generate_and_send_tts(
            phrase,
            config,
            on_audio,
            on_error,
            _tts_failure_logged=tts_failure_logged,
            trace_label="pre_tool_filler",
        )

    async def tool_exec(name: str, args: dict) -> str:
        if name in CALENDAR_TOOL_NAMES:
            normalized = normalize_tool_args(args)
            if name == "create_appointment" and caller_phone and not normalized.get("caller_phone"):
                normalized["caller_phone"] = caller_phone
            key = (name, json.dumps(normalized, sort_keys=True, separators=(",", ":")))
            if key in tool_cache:
                logger.info(
                    "[CALL_DIAG] tool_exec_dedupe_hit tool=%s key=%s",
                    name,
                    key[1][:200],
                )
                return tool_cache[key]

            await _maybe_pre_tool_speech(name)

            if name == "create_appointment":
                has_start = bool(normalized.get("start_time") or normalized.get("date_text"))
                has_duration = bool(normalized.get("duration_minutes"))
                has_summary = bool((normalized.get("summary") or "").strip())
                missing = []
                if not has_start:
                    missing.append("start_time/date_text")
                if not has_duration:
                    missing.append("duration_minutes")
                if not has_summary:
                    missing.append("summary")
                logger.info(
                    "[CALL_DIAG] tool_exec_call tool=create_appointment has_start=%s has_duration=%s has_summary=%s missing=%s",
                    has_start,
                    has_duration,
                    has_summary,
                    ",".join(missing) if missing else "",
                )
            else:
                logger.info(
                    "[CALL_DIAG] tool_exec_call tool=%s args=%s",
                    name,
                    key[1][:250],
                )

            if not (base_url and api_key and rec_id):
                result = '{"success": false, "error": "calendar_not_configured"}'
                mark_voice_event(
                    call_control_id,
                    "calendar_tool_response",
                    commit_id=config.get("active_turn_commit_id"),
                    tool=name,
                    success=False,
                    error="calendar_not_configured",
                    cached=False,
                )
                tool_cache[key] = result
                return result

            t_tool_start = time.perf_counter()
            logger.info("[BOOKING_LATENCY] calendar_tool_start tool=%s t=%.3f", name, t_tool_start)
            mark_voice_event(
                call_control_id,
                "calendar_tool_request",
                commit_id=config.get("active_turn_commit_id"),
                tool=name,
                cached=False,
            )
            result = await call_calendar_tool(base_url, api_key, rec_id, name, normalized, call_control_id=call_control_id)
            t_tool_end = time.perf_counter()
            logger.info("[BOOKING_LATENCY] calendar_tool_end tool=%s duration_ms=%.0f", name, (t_tool_end - t_tool_start) * 1000)
            tool_success: bool | None = None
            tool_error: str | None = None
            try:
                parsed_for_trace = json.loads(result) if result else {}
                if isinstance(parsed_for_trace, dict):
                    raw_success = parsed_for_trace.get("success")
                    tool_success = raw_success if isinstance(raw_success, bool) else None
                    raw_error = parsed_for_trace.get("error")
                    tool_error = raw_error if isinstance(raw_error, str) else None
            except (json.JSONDecodeError, TypeError):
                tool_error = "unparseable_result"
            mark_voice_event(
                call_control_id,
                "calendar_tool_response",
                commit_id=config.get("active_turn_commit_id"),
                tool=name,
                success=tool_success,
                error=tool_error,
                cached=False,
                duration_ms=int((t_tool_end - t_tool_start) * 1000),
            )
            if name == "check_availability" and result:
                try:
                    parsed = json.loads(result)
                    if parsed.get("success") is True:
                        offered_slots_state["exact_slots"] = parsed.get("exact_slots") or []
                        offered_slots_state["suggested_slots"] = parsed.get("suggested_slots") or []
                        offered_slots_state["summary_periods"] = parsed.get("summary_periods") or []
                        dt = (normalized.get("date_text") or "").strip()
                        if dt:
                            offered_slots_state["last_date_text"] = dt
                except (json.JSONDecodeError, TypeError):
                    pass
            if name == "create_appointment" and result:
                try:
                    parsed = json.loads(result)
                    if parsed.get("success") is True:
                        sms = parsed.get("sms_followup")
                        vs = config.get("voice_session")
                        if sms and isinstance(vs, dict):
                            vs["sms"] = sms
                        for f in (
                            "followup_message_resolved",
                            "payment_link",
                            "meeting_instructions",
                            "owner_selected_platform",
                            "sms_followup",
                        ):
                            parsed.pop(f, None)
                        result = json.dumps(parsed)
                        offered_slots_state["exact_slots"] = []
                        offered_slots_state["suggested_slots"] = []
                        offered_slots_state["summary_periods"] = []
                        vs = config.get("voice_session")
                        if isinstance(vs, dict):
                            vs["booking_completed"] = True
                except (json.JSONDecodeError, TypeError):
                    pass
            tool_cache[key] = result
            return result

        return '{"success": false, "error": "Unknown tool: ' + name + '"}'

    return tool_exec
