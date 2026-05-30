"""Ordered deterministic turn router for common voice-call utterances."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Optional

from voice.intent_router import resolve_calendar_fast_path
from voice.pipeline_transcript import (
    extract_date_text_hint,
    extract_time_hint,
    is_availability_intent,
    normalize_for_whitelist,
)
from voice.slot_selection import SlotResolution


@dataclass
class DeterministicTurnResult:
    handled: bool = False
    reply: Optional[str] = None
    tool_name: Optional[str] = None
    tool_args: dict[str, Any] = field(default_factory=dict)
    reason: str = "unhandled"
    requires_llm_fallback: bool = False
    requested_date: Optional[str] = None
    requested_time: Optional[str] = None
    slot_fast: bool = False


def _trim_spoken_repeat(text: str, *, max_chars: int = 240) -> str:
    spoken = " ".join((text or "").split())
    if len(spoken) <= max_chars:
        return spoken
    return spoken[: max_chars - 3].rstrip() + "..."


def _bare_hour_request(norm: str) -> str | None:
    if " am" in norm or " pm" in norm or re.search(r"\b\d{1,2}\s*(am|pm)\b", norm):
        return None
    m = re.search(r"\b(?:can you do|book me for|schedule me for|make it|do)\s+(\d{1,2})\b", norm)
    if not m:
        return None
    hour = int(m.group(1))
    if 1 <= hour <= 12:
        return str(hour)
    return None


def resolve_deterministic_turn(
    user_text: str,
    *,
    offered_slots_state: dict[str, Any],
    use_calendar: bool,
    slot_pre_attempted: bool,
    last_slot_resolution: Optional[SlotResolution],
    last_assistant_text: str = "",
) -> DeterministicTurnResult:
    """Return a deterministic reply/tool action for top known utterances."""
    norm = normalize_for_whitelist(user_text)
    if not norm:
        return DeterministicTurnResult()

    if norm in {"hello", "hi", "hey"}:
        return DeterministicTurnResult(
            handled=True,
            reply="Hi. How can I help?",
            reason="greeting",
        )

    if norm in {"can you hear me", "you there", "anybody there"} or "are you there" in norm:
        return DeterministicTurnResult(
            handled=True,
            reply="Yes, I'm here. How can I help?",
            reason="presence_check",
        )

    if any(p in norm for p in ("repeat that", "say that again", "can you repeat", "what did you say")):
        if last_assistant_text:
            return DeterministicTurnResult(
                handled=True,
                reply=f"Of course. {_trim_spoken_repeat(last_assistant_text)}",
                reason="repeat_last_assistant",
            )
        return DeterministicTurnResult(
            handled=True,
            reply="Of course. What would you like me to repeat?",
            reason="repeat_without_context",
        )

    bare_hour = _bare_hour_request(norm)
    if bare_hour:
        return DeterministicTurnResult(
            handled=True,
            reply=f"Sure — did you mean {bare_hour} AM or {bare_hour} PM, and which day?",
            reason="clarify_bare_hour",
        )

    date_hint = extract_date_text_hint(user_text)
    time_hint = extract_time_hint(user_text)
    if use_calendar and time_hint and not date_hint and is_availability_intent(user_text):
        return DeterministicTurnResult(
            handled=True,
            reply=f"Sure — which day should I check for {time_hint}?",
            reason="clarify_time_without_date",
        )

    if use_calendar:
        fp = resolve_calendar_fast_path(
            user_text,
            offered_slots_state,
            slot_pre_attempted=slot_pre_attempted,
            last_slot_resolution=last_slot_resolution,
        )
        if fp.fast_tool_name:
            return DeterministicTurnResult(
                handled=True,
                tool_name=fp.fast_tool_name,
                tool_args=fp.fast_tool_args,
                reason=f"calendar_{fp.fast_tool_name}",
                requested_date=fp.fast_date,
                requested_time=fp.fast_time,
                slot_fast=fp.slot_fast,
            )

    return DeterministicTurnResult()
