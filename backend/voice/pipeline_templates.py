"""Deterministic spoken responses (response templates) from tool results, SMS lines, availability guard."""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime
from typing import Any, Optional

from telnyx.sms_delivery_registry import get_delivery_status
from voice.pipeline_transcript import is_post_booking_followup_message, normalize_for_whitelist

logger = logging.getLogger(__name__)


def _extract_spoken_slots(text: str) -> list[str]:
    """Best-effort extraction of time-like mentions from spoken response for guard logging."""
    if not text or not text.strip():
        return []
    t = text.lower()
    found: list[str] = []
    for m in re.finditer(r"\b(\d{1,2})\s*(?::\d{2})?\s*(am|pm|a\.m\.|p\.m\.|o'?clock)?\b", t, re.IGNORECASE):
        found.append(m.group(0).strip())
    for period in ("morning", "afternoon", "evening"):
        if period in t:
            found.append(period)
    return found


def log_availability_guard(response: str, tool_slots: dict[str, Any]) -> None:
    """Log tool slots vs spoken slots; warn if response mentions times not in tool result."""
    tool_exact = tool_slots.get("exact_slots") or []
    tool_suggested = tool_slots.get("suggested_slots") or []
    tool_periods = tool_slots.get("summary_periods") or []
    slots_str = ",".join(tool_exact or tool_suggested)
    logger.info("[AVAILABILITY_SPOKEN_GUARD] tool_slots=%s", slots_str or "(none)")
    spoken = _extract_spoken_slots(response)
    logger.info("[AVAILABILITY_SPOKEN_GUARD] spoken_slots=%s", ",".join(spoken) if spoken else "(none)")
    if not spoken:
        return
    allowed = set(str(s) for s in (tool_exact or tool_suggested))
    allowed_periods = set(p.lower() for p in tool_periods)
    for s in spoken:
        s_lower = s.lower()
        if s_lower in allowed_periods:
            continue
        if any(s_lower in a or a in s_lower for a in allowed):
            continue
        if re.match(r"^\d", s) and not allowed:
            logger.warning(
                "[AVAILABILITY_SPOKEN_GUARD] spoken time %r may not be in tool result tool_slots=%s",
                s,
                slots_str,
            )
        elif re.match(r"^\d", s):
            logger.warning(
                "[AVAILABILITY_SPOKEN_GUARD] spoken time %r differs from tool slots=%s",
                s,
                slots_str,
            )


def to_spoken_slot(slot: str) -> str:
    try:
        dt = datetime.fromisoformat(slot.replace("Z", "+00:00"))
        return dt.strftime("%-I:%M %p").lower()
    except Exception:
        return slot


def slots_sentence(slots: list[str]) -> str:
    spoken = [to_spoken_slot(s) for s in slots[:3]]
    if not spoken:
        return ""
    if len(spoken) == 1:
        return spoken[0]
    if len(spoken) == 2:
        return f"{spoken[0]} or {spoken[1]}"
    return f"{spoken[0]}, {spoken[1]}, or {spoken[2]}"


def _openings_line_from_summary_periods(periods: list[str]) -> str:
    """Spoken bucket summary (morning / afternoon / evening) from tool `summary_periods`."""
    order = ("morning", "afternoon", "evening")
    seen = {p.lower() for p in periods if isinstance(p, str)}
    ordered = [p for p in order if p in seen]
    if not ordered:
        return "I have some openings"
    if len(ordered) == 1:
        return f"I have {ordered[0]} openings"
    if len(ordered) == 2:
        return f"I have {ordered[0]} and {ordered[1]} openings"
    return f"I have {ordered[0]}, {ordered[1]}, and {ordered[2]} openings"


# Align with calendar_api._availability._PERIOD_HOURS (local hour buckets)
_SLOT_PERIOD_HOURS = (
    ("morning", 6, 12),
    ("afternoon", 12, 17),
    ("evening", 17, 21),
)


def _infer_summary_periods_from_slots(slots: list[str]) -> list[str]:
    """Derive morning/afternoon/evening labels when API omitted summary_periods."""
    seen: set[str] = set()
    for s in slots:
        try:
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
            h = dt.hour
            for name, lo, hi in _SLOT_PERIOD_HOURS:
                if lo <= h < hi:
                    seen.add(name)
                    break
        except (ValueError, TypeError):
            continue
    order = ("morning", "afternoon", "evening")
    return [p for p in order if p in seen]


def _compact_range_spoken(slots: list[str]) -> str:
    """Min–max spoken range for offered slots (same-day business hours)."""
    dts: list[datetime] = []
    for s in slots:
        try:
            dts.append(datetime.fromisoformat(s.replace("Z", "+00:00")))
        except (ValueError, TypeError):
            continue
    if not dts:
        return ""
    dts.sort()
    a, b = dts[0], dts[-1]
    if a == b:
        return to_spoken_slot(a.isoformat())
    return f"{to_spoken_slot(a.isoformat())} to {to_spoken_slot(b.isoformat())}"


def _availability_reply_bucket_first(day_text: str, slots: list[str], periods_norm: list[str]) -> str:
    """Step 1: bucket summary; ask preference before listing every slot (reduces cognitive load)."""
    if len(periods_norm) >= 2:
        bucket = _openings_line_from_summary_periods(periods_norm)
        return f"I checked {day_text}—{bucket}. What works best for you?"
    if len(periods_norm) == 1:
        p = periods_norm[0]
        span = _compact_range_spoken(slots)
        if span:
            return f"I only have {p} openings {day_text}, around {span}. Which time works best for you?"
        return f"I only have {p} openings {day_text}. Which time works best for you?"
    return f"I found {slots_sentence(slots)} for {day_text}. Which works best?"


def unavailable_requested_time_reply(
    requested_time: str,
    offered_slots_state: dict[str, Any],
) -> str:
    """Reply when caller asks for a concrete time that is not in the just-offered slots."""
    time_text = (requested_time or "that time").strip() or "that time"
    periods = offered_slots_state.get("summary_periods") if isinstance(offered_slots_state, dict) else []
    periods_norm = [p.lower() for p in (periods or []) if isinstance(p, str)]
    slots = []
    if isinstance(offered_slots_state, dict):
        slots = offered_slots_state.get("exact_slots") or offered_slots_state.get("suggested_slots") or []
    if periods_norm:
        return f"I don't see {time_text} in the openings I found. {_openings_line_from_summary_periods(periods_norm)}. What works best?"
    if slots:
        return f"I don't see {time_text} available. I found {slots_sentence(slots)}. Which works best?"
    return f"I don't see {time_text} available. Want me to check another time?"


def truth_aware_sms_line(voice_session: dict[str, Any] | None) -> str:
    """One short line about confirmation text; never claim delivered if API failed or delivery failed."""
    vs = voice_session or {}
    sms = vs.get("sms") if isinstance(vs.get("sms"), dict) else {}
    if not sms.get("attempted"):
        return ""
    if not sms.get("api_accepted"):
        return " I wasn't able to send a confirmation text—please save this time or call back if anything changes."
    msg_id = (sms.get("telnyx_message_id") or "").strip()
    delivery = get_delivery_status(msg_id) if msg_id else None
    if delivery == "delivery_failed":
        if sms.get("from_number_is_toll_free"):
            return (
                " A confirmation text didn't go through—if you're expecting SMS, toll-free numbers often need "
                "verification with your carrier provider first."
            )
        return " A confirmation text didn't go through—please save this time or call us if you need to change it."
    if delivery in ("delivered",):
        return " You should get a confirmation text shortly."
    return (
        " I'll also send a confirmation text if messaging delivery goes through—if you don't see it, "
        "your appointment is still booked."
    )


def deterministic_farewell_reply(user_text: str) -> str:
    """Short spoken reply for courtesy goodbyes; caller already matched is_farewell_courtesy_intent."""
    norm = normalize_for_whitelist(user_text)
    if "have a great" in norm or "have a good" in norm:
        if "night" in norm or "evening" in norm:
            return "Of course. Have a great night."
        if "day" in norm or "weekend" in norm:
            return "Of course. Have a great day."
    if ("thank" in norm or "thanks" in norm) and ("night" in norm or "evening" in norm):
        return "Of course. Have a great night."
    if ("thank" in norm or "thanks" in norm) and "day" in norm:
        return "Of course. Have a great day."
    if "appreciate" in norm:
        return "You're welcome. Take care."
    return "You too. Goodbye."


def template_from_tool_result(
    tool_name: str,
    result_json: str,
    requested_date: Optional[str],
    requested_time: Optional[str],
    *,
    voice_session: Optional[dict[str, Any]] = None,
    list_exact_times: bool = False,
) -> Optional[str]:
    try:
        parsed = json.loads(result_json or "{}")
    except Exception:
        return None
    if parsed.get("success") is not True:
        if tool_name == "check_availability":
            return "I couldn't fetch availability just now. Want me to try a different day?"
        if tool_name == "create_appointment":
            return "I couldn't complete that booking yet. Could you repeat the date and time?"
        return None

    if tool_name == "check_availability":
        slots = parsed.get("exact_slots") or parsed.get("suggested_slots") or []
        if slots:
            day_text = requested_date or "that day"
            if requested_time and parsed.get("slot_available") is True:
                return f"Yes, {requested_time} {day_text} is available. Would you like me to book it?"
            if requested_time and parsed.get("slot_available") is False:
                return f"I don't see {requested_time} available. I found {slots_sentence(slots)}. Which works best?"
            if list_exact_times:
                return f"I found {slots_sentence(slots)} for {day_text}. Which works best?"
            periods = parsed.get("summary_periods") if isinstance(parsed.get("summary_periods"), list) else []
            periods_norm = [p.lower() for p in periods if isinstance(p, str)]
            if not periods_norm:
                periods_norm = _infer_summary_periods_from_slots(slots)
            return _availability_reply_bucket_first(day_text, slots, periods_norm)
        return "I don't have open slots in that window. Want me to check another day?"

    if tool_name == "create_appointment":
        start = (parsed.get("start_time") or "").strip()
        sms_line = truth_aware_sms_line(voice_session)
        if start:
            base = f"You're all set for {to_spoken_slot(start)}."
            return base + sms_line if sms_line else base
        if requested_time:
            date_part = requested_date or "that day"
            base = f"You're all set for {requested_time} {date_part}."
            return base + sms_line if sms_line else base
        base = "You're all set."
        return base + sms_line if sms_line else base
    return None


def deterministic_post_booking_reply(user_text: str, voice_session: dict[str, Any]) -> Optional[str]:
    """One short truth-aware reply for common post-booking questions; no chains."""
    if not voice_session.get("booking_completed"):
        return None
    if not is_post_booking_followup_message(user_text):
        return None
    sms_line = truth_aware_sms_line(voice_session).strip()
    if sms_line:
        return f"You're all set.{sms_line}"
    return "You're all set. If anything changes, just call us back."
