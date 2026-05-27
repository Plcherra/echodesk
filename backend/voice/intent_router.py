"""Heuristic routing: calendar fast path (availability vs booking) before Grok."""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any, Optional

from voice.pipeline_transcript import (
    extract_date_text_hint,
    extract_time_hint,
    is_availability_intent,
    is_booking_confirmation_intent,
)
from voice.slot_selection import (
    SlotResolution,
    is_new_availability_search_intent,
    resolve_slot_selection,
)

logger = logging.getLogger(__name__)


@dataclass
class CalendarFastPathDecision:
    fast_tool_name: Optional[str]
    fast_tool_args: dict[str, Any]
    fast_date: Optional[str]
    fast_time: Optional[str]
    slot_fast: bool


def resolve_calendar_fast_path(
    user_text: str,
    offered_slots_state: dict[str, Any],
    *,
    slot_pre_attempted: bool,
    last_slot_resolution: Optional[SlotResolution],
) -> CalendarFastPathDecision:
    """Choose check_availability vs create_appointment and tool args without LLM when possible."""
    fast_date = extract_date_text_hint(user_text)
    fast_time = extract_time_hint(user_text)
    fast_tool_name = None
    fast_tool_args: dict[str, Any] = {}
    slot_fast = False

    def _date_and_time_text() -> str:
        return " ".join(
            [p for p in [fast_date, ("at " + fast_time) if fast_time else None] if p]
        ).strip()

    sr_pre = last_slot_resolution
    if slot_pre_attempted and sr_pre and sr_pre.ok and sr_pre.slot_iso:
        slot_fast = True
        fast_tool_name = "create_appointment"
        fast_tool_args = {
            "start_time": sr_pre.slot_iso,
            "duration_minutes": 30,
            "summary": "Appointment",
            "generic_appointment_requested": True,
        }
        fast_date = (offered_slots_state.get("last_date_text") or "").strip() or fast_date
        fast_time = None
        logger.info(
            "[CALL_DIAG] slot_selection_fast_path_selected transcript=%s",
            user_text[:120],
        )
    elif not slot_pre_attempted and not is_new_availability_search_intent(user_text):
        sr2 = resolve_slot_selection(user_text, offered_slots_state)
        if sr2.ok and sr2.slot_iso:
            slot_fast = True
            fast_tool_name = "create_appointment"
            fast_tool_args = {
                "start_time": sr2.slot_iso,
                "duration_minutes": 30,
                "summary": "Appointment",
                "generic_appointment_requested": True,
            }
            fast_date = (offered_slots_state.get("last_date_text") or "").strip() or fast_date
            fast_time = None
            logger.info(
                "[CALL_DIAG] slot_selection_fast_path_selected transcript=%s",
                user_text[:120],
            )
            logger.info(
                "[CALL_DIAG] slot_selection_resolved slot=%s source=%s",
                sr2.slot_iso[:48],
                sr2.source,
            )
        elif sr2.ambiguous:
            logger.info("[CALL_DIAG] slot_selection_ambiguous transcript=%s", user_text[:120])
            logger.info("[CALL_DIAG] slot_selection_fallback_to_llm reason=ambiguous")
        else:
            logger.debug("[CALL_DIAG] slot_selection_no_match transcript=%s", user_text[:80])

    if not slot_fast and is_booking_confirmation_intent(user_text):
        fast_tool_name = "create_appointment"
        date_and_time = _date_and_time_text()
        if date_and_time:
            fast_tool_args["date_text"] = date_and_time
        if not fast_tool_args.get("date_text"):
            fast_tool_name = None
        else:
            fast_tool_args["summary"] = "Appointment"
            fast_tool_args["generic_appointment_requested"] = True
    elif not slot_fast and is_availability_intent(user_text):
        fast_tool_name = "check_availability"
        fast_tool_args = {
            "date_text": _date_and_time_text() or fast_date or "tomorrow",
            "generic_appointment_requested": True,
        }

    if fast_tool_name:
        logger.info(
            "[CALL_DIAG] fast_path_selected tool=%s transcript=%s args=%s",
            fast_tool_name,
            user_text[:120],
            json.dumps(fast_tool_args, separators=(",", ":"), sort_keys=True)[:220],
        )

    return CalendarFastPathDecision(
        fast_tool_name=fast_tool_name,
        fast_tool_args=fast_tool_args,
        fast_date=fast_date,
        fast_time=fast_time,
        slot_fast=slot_fast,
    )
