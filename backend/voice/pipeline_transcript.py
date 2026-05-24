"""Transcript normalization, guards, and spoken-intent heuristics for the voice pipeline.

Pure functions only — keeps turn-taking logic testable without Deepgram/Grok.
"""

from __future__ import annotations

import re
from typing import Optional

FILLER_WORDS = frozenset({"um", "uh", "hmm", "eh", "er", "ah", "like", "well", "so"})

# Normalized for matching: lowercase, strip punctuation, collapse spaces (e.g. "9 am" -> "9am").
SHORT_UTTERANCE_WHITELIST = frozenset({
    "hello", "hi", "hey", "yes", "yeah", "yup", "no", "okay", "ok",
    "book", "booking", "pricing", "price", "tomorrow", "today",
    "9am", "9 am", "10am", "10 am", "11am", "11 am", "8am", "8 am",
    "can you hear me", "you there", "anybody there",
})

INCOMPLETE_PHRASE_ENDINGS = (
    " to",
    " for",
    " at",
    " on",
    " i want",
    " i wanna",
    " i need",
    " can you",
    " could you",
    " tomorrow at",
    " today at",
)
INCOMPLETE_SINGLE_WORDS = frozenset({"to", "for", "at", "on"})
INTENT_HINTS = (
    "book",
    "appointment",
    "availability",
    "available",
    "spot",
    "tomorrow",
    "today",
    "reschedule",
    "cancel",
    "price",
    "pricing",
)


def normalize_for_whitelist(text: str) -> str:
    """Normalize transcript for whitelist matching: lowercase, strip punctuation, collapse spaces."""
    if not text:
        return ""
    s = (text or "").strip().lower()
    s = re.sub(r"[?!.,;:]+", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def passes_transcript_guard(text: str) -> bool:
    """Allow transcripts that are long enough, in whitelist, or substantive. Reject filler-only."""
    s = (text or "").strip()
    if len(s) < 2:
        return False
    norm = normalize_for_whitelist(s)
    if norm in SHORT_UTTERANCE_WHITELIST:
        return True
    if len(s) == 2 and norm not in SHORT_UTTERANCE_WHITELIST:
        return False
    words = s.lower().split()
    if len(words) == 1 and words[0] in FILLER_WORDS:
        return False
    if len(words) <= 2 and all(w in FILLER_WORDS for w in words):
        return False
    return True


def is_incomplete_transcript(text: str) -> bool:
    """Return True if transcript ends in a dangling phrase and caller likely has more to say."""
    s = (text or "").strip().lower()
    if not s:
        return False
    if s in INCOMPLETE_SINGLE_WORDS:
        return True
    return any(s.endswith(ending) or s == ending.strip() for ending in INCOMPLETE_PHRASE_ENDINGS)


def is_whitelisted_short_utterance(text: str) -> bool:
    """Return True if transcript is a known short complete utterance that should trigger immediately."""
    norm = normalize_for_whitelist(text)
    if not norm:
        return False
    if norm in SHORT_UTTERANCE_WHITELIST:
        return True
    collapsed = norm.replace(" ", "")
    return collapsed in SHORT_UTTERANCE_WHITELIST


def is_farewell_courtesy_intent(text: str) -> bool:
    """Terminal courtesy / goodbye — should dispatch immediately, not sit behind debounce."""
    norm = normalize_for_whitelist(text)
    if not norm:
        return False
    # Avoid matching "good morning" as a booking daypart
    if norm in ("good morning", "morning"):
        return False
    if any(
        p in norm
        for p in (
            "goodbye",
            "bye bye",
            "talk to you later",
            "see you later",
            "take care",
            "have a good one",
        )
    ):
        return True
    if re.search(r"\bbye\b", norm) and len(norm.split()) <= 12:
        return True
    if ("thank" in norm or "thanks" in norm) and any(
        x in norm for x in ("night", "day", "bye", "great", "appreciate")
    ):
        return True
    if "have a great" in norm or "have a good" in norm:
        return True
    return False


def is_post_booking_followup_message(text: str) -> bool:
    """Common follow-up after booking; should not sit in debounce limbo."""
    norm = normalize_for_whitelist(text)
    if not norm:
        return False
    return any(
        p in norm
        for p in (
            "anything else",
            "any thing else",
            "need to know",
            "is that all",
            "that all",
            "something else",
            "what else",
            "one more thing",
            "anything i should",
        )
    )


def contains_clear_intent(text: str) -> bool:
    """True when transcript clearly expresses booking/help intent."""
    norm = normalize_for_whitelist(text)
    if not norm:
        return False
    if is_post_booking_followup_message(text):
        return True
    if extract_time_hint(text) is not None and any(
        h in norm
        for h in (
            "have",
            "available",
            "availability",
            "opening",
            "openings",
            "slot",
            "spot",
            "book",
            "schedule",
        )
    ):
        return True
    if "?" in (text or "") and any(h in norm for h in INTENT_HINTS):
        return True
    return any(h in norm for h in INTENT_HINTS)


def extract_date_text_hint(text: str) -> Optional[str]:
    norm = normalize_for_whitelist(text)
    if "tomorrow" in norm:
        return "tomorrow"
    if "today" in norm:
        return "today"
    return None


def extract_time_hint(text: str) -> Optional[str]:
    norm = normalize_for_whitelist(text)
    m = re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", norm, flags=re.IGNORECASE)
    if m:
        hh = m.group(1)
        mm = m.group(2)
        ampm = m.group(3).lower()
        return f"{hh}:{mm} {ampm}" if mm else f"{hh} {ampm}"
    words = {
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    }
    m2 = re.search(r"\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s*(am|pm)\b", norm)
    if m2:
        return f"{words[m2.group(1)]} {m2.group(2)}"
    return None


def is_booking_confirmation_intent(text: str) -> bool:
    norm = normalize_for_whitelist(text)
    if not norm:
        return False
    has_time = extract_time_hint(text) is not None
    wants_booking = any(k in norm for k in ("book", "please", "that works", "works", "schedule"))
    return has_time and wants_booking


def is_availability_intent(text: str) -> bool:
    norm = normalize_for_whitelist(text)
    return any(k in norm for k in ("availability", "available", "spot", "book", "tomorrow", "today"))
