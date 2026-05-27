"""
Deterministic slot selection against the last offered availability slots only.

Resolve user selection only against the most recently offered slots unless the user
explicitly asks for a new search (see is_new_availability_search_intent).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Optional


@dataclass
class SlotResolution:
    ok: bool
    slot_iso: Optional[str]
    source: str  # exact_time_match | ordinal | single_slot_affirm | none
    ambiguous: bool = False


# Local hour buckets — keep aligned with calendar_api._availability._PERIOD_HOURS
_DAYPART_RANGES = (
    ("morning", 6, 12),
    ("afternoon", 12, 17),
    ("evening", 17, 21),
)

_WORD_TO_NUM = {
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
}

_ORDINAL_WORDS = {
    "first": 0,
    "1st": 0,
    "second": 1,
    "2nd": 1,
    "third": 2,
    "3rd": 2,
    "fourth": 3,
    "4th": 3,
}


def _normalize(text: str) -> str:
    s = (text or "").strip().lower()
    s = re.sub(r"[?!.,;:]+", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def is_new_availability_search_intent(text: str) -> bool:
    """True when the caller is asking for a new availability search, not picking an offered slot."""
    norm = _normalize(text)
    if not norm:
        return False
    if any(
        p in norm
        for p in (
            "another day",
            "different day",
            "other day",
            "check another",
            "look at another",
            "try another day",
            "what about monday",
            "what about tuesday",
            "what about wednesday",
            "what about thursday",
            "what about friday",
            "what about saturday",
            "what about sunday",
            "next week",
            "availability for",
            "openings for",
            "slots for",
            "anything for tomorrow",
            "anything tomorrow",
            "what time do you have",
            "what times do you have",
            "what do you have",
            "do you have",
            "do you got",
            "you have anything",
            "any openings",
            "any slots",
        )
    ):
        return True
    if re.search(r"\b(what|which)\s+(time|times|slots|openings)\b", norm):
        return True
    if re.search(r"\b(do|did|can|could)\s+you\s+(have|see|find|check)\b", norm):
        return True
    if re.search(r"\b(check|see|find)\s+(availability|openings|slots)\b", norm):
        return True
    if "tomorrow" in norm and any(x in norm for x in ("check", "see", "find", "availability", "open")):
        return True
    return False


def _parse_slot_dt(iso: str) -> Optional[datetime]:
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except Exception:
        return None


def _offered_list(state: dict[str, Any]) -> list[str]:
    exact = state.get("exact_slots") or []
    sug = state.get("suggested_slots") or []
    return [str(x) for x in (exact or sug) if x]


def recent_offered_slots_present(offered_slots_state: dict[str, Any]) -> bool:
    """True when the pipeline has last-offered exact or suggested slots to resolve against."""
    return bool(_offered_list(offered_slots_state))


def _hour_minute(dt: datetime) -> tuple[int, int]:
    return dt.hour, dt.minute


def _daypart_booking_intent(norm: str, daypart: str) -> bool:
    """True when user is choosing a daypart to book, not e.g. 'good morning'."""
    if any(k in norm for k in ("book", "schedule", "appointment", "reserve")):
        return True
    if f"for the {daypart}" in norm or f"in the {daypart}" in norm:
        return True
    if re.search(rf"\b{re.escape(daypart)}\s+(slot|time|opening|appointment)\b", norm):
        return True
    return False


def resolve_slot_selection(
    text: str,
    offered_slots_state: dict[str, Any],
) -> SlotResolution:
    """
    Map caller text to one of the offered ISO slots. Never invent a time outside the list.
    """
    offered = _offered_list(offered_slots_state)
    if not offered:
        return SlotResolution(False, None, "none", ambiguous=False)

    parsed_slots = [(s, _parse_slot_dt(s)) for s in offered]
    parsed_slots = [(s, dt) for s, dt in parsed_slots if dt is not None]
    if not parsed_slots:
        return SlotResolution(False, None, "none", ambiguous=False)

    norm = _normalize(text)

    # Daypart: "book me for the morning" → first offered slot in that window (chronological)
    for name, lo, hi in _DAYPART_RANGES:
        if not re.search(rf"\b{re.escape(name)}\b", norm):
            continue
        if not _daypart_booking_intent(norm, name):
            continue
        in_bucket = [(s, dt) for s, dt in parsed_slots if lo <= dt.hour < hi]
        in_bucket.sort(key=lambda x: x[1])
        if len(in_bucket) >= 1:
            return SlotResolution(True, in_bucket[0][0], "daypart_bucket", ambiguous=False)
        return SlotResolution(False, None, "none", ambiguous=False)

    # Single slot + affirmation
    if len(parsed_slots) == 1:
        if any(
            k in norm
            for k in (
                "that works",
                "works for me",
                "sounds good",
                "perfect",
                "yes",
                "yeah",
                "yep",
                "ok",
                "okay",
                "book it",
                "do it",
                "take it",
            )
        ):
            return SlotResolution(True, parsed_slots[0][0], "single_slot_affirm", ambiguous=False)

    # Ordinal: first, second, third / the second one / book 2 (index)
    for ow, idx in sorted(_ORDINAL_WORDS.items(), key=lambda kv: -len(kv[0])):
        if re.search(rf"\b{re.escape(ow)}\b", norm):
            if 0 <= idx < len(parsed_slots):
                return SlotResolution(True, parsed_slots[idx][0], "ordinal", ambiguous=False)
            return SlotResolution(False, None, "none", ambiguous=True)

    m_ord = re.search(r"\b(book|pick|take)\s+(\d)\b", norm)
    if m_ord:
        idx = int(m_ord.group(2)) - 1
        if 0 <= idx < len(parsed_slots):
            return SlotResolution(True, parsed_slots[idx][0], "ordinal_digit", ambiguous=False)

    # Time digits: 3 pm, 3:00pm, 15:00
    hm_user: Optional[tuple[int, int]] = None
    m = re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", norm)
    if m:
        h = int(m.group(1))
        minute = int(m.group(2) or 0)
        ap = m.group(3).lower()
        if ap == "pm" and h != 12:
            h += 12
        if ap == "am" and h == 12:
            h = 0
        if ap == "am" and 1 <= h <= 11:
            pass
        hm_user = (h % 24, minute)
    else:
        m2 = re.search(
            r"\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s*(am|pm)\b",
            norm,
        )
        if m2:
            h = _WORD_TO_NUM.get(m2.group(1), 0)
            ap = m2.group(2).lower()
            if ap == "pm" and h != 12:
                h += 12
            if ap == "am" and h == 12:
                h = 0
            hm_user = (h % 24, 0)

    if hm_user is not None:
        matches: list[str] = []
        uh, um = hm_user
        for s, dt in parsed_slots:
            sh, sm = _hour_minute(dt)
            if sh == uh and sm == um:
                matches.append(s)
            # Half-hour: allow 3 / 3:30 match "around 3"
            elif uh == sh and abs(sm - um) <= 30 and ("around" in norm or "about" in norm):
                matches.append(s)
        if len(matches) == 1:
            return SlotResolution(True, matches[0], "exact_time_match", ambiguous=False)
        if len(matches) > 1:
            return SlotResolution(False, None, "none", ambiguous=True)
        # No exact match on same hour: try same hour only (e.g. 3 pm vs 3:30 offered)
        loose: list[str] = []
        for s, dt in parsed_slots:
            sh, _ = _hour_minute(dt)
            if sh == uh:
                loose.append(s)
        if len(loose) == 1:
            return SlotResolution(True, loose[0], "hour_match", ambiguous=False)
        if len(loose) > 1:
            return SlotResolution(False, None, "none", ambiguous=True)
        return SlotResolution(False, None, "none", ambiguous=False)

    return SlotResolution(False, None, "none", ambiguous=False)
