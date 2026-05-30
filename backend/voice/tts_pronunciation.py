"""Pronunciation normalization for plain-text Google TTS over telephone audio."""

from __future__ import annotations

import re


_PHONE_RE = re.compile(
    r"(?<!\d)(?:\+?1[\s.\-()]*)?\(?(\d{3})\)?[\s.\-]*(\d{3})[\s.\-]*(\d{4})(?!\d)"
)
_PRICE_RE = re.compile(r"(?<!\w)\$(\d{1,6})(?:\.(\d{1,2}))?(?!\w)")
_TIME_RE = re.compile(r"\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\b", re.IGNORECASE)

_ACRONYM_REPLACEMENTS: tuple[tuple[re.Pattern[str], str], ...] = tuple(
    (re.compile(rf"\b{token}\b", re.IGNORECASE), spoken)
    for token, spoken in (
        ("AI", "A I"),
        ("API", "A P I"),
        ("SMS", "S M S"),
        ("URL", "U R L"),
        ("ID", "I D"),
        ("FAQ", "F A Q"),
        ("CRM", "C R M"),
        ("TTS", "T T S"),
        ("STT", "S T T"),
    )
)


def _digits_spoken(text: str) -> str:
    return " ".join(text)


def _phone_repl(match: re.Match[str]) -> str:
    area, prefix, line = match.groups()
    return f"{_digits_spoken(area)}, {_digits_spoken(prefix)}, {_digits_spoken(line)}"


def _price_repl(match: re.Match[str]) -> str:
    dollars_raw, cents_raw = match.groups()
    dollars = int(dollars_raw)
    dollar_unit = "dollar" if dollars == 1 else "dollars"
    if cents_raw is None:
        return f"{dollars} {dollar_unit}"
    cents = int(cents_raw.ljust(2, "0")[:2])
    if cents == 0:
        return f"{dollars} {dollar_unit}"
    cent_unit = "cent" if cents == 1 else "cents"
    return f"{dollars} {dollar_unit} and {cents} {cent_unit}"


def _time_repl(match: re.Match[str]) -> str:
    hour, minute, meridiem = match.groups()
    suffix = "A M" if meridiem.lower().startswith("a") else "P M"
    if minute and minute != "00":
        return f"{int(hour)} {minute} {suffix}"
    return f"{int(hour)} {suffix}"


def normalize_pronunciation_for_tts(text: str) -> str:
    """Normalize text for clearer speech while preserving plain-text TTS input."""
    if not text or not text.strip():
        return text

    out = text
    out = _PHONE_RE.sub(_phone_repl, out)
    out = _PRICE_RE.sub(_price_repl, out)
    out = _TIME_RE.sub(_time_repl, out)
    for pattern, spoken in _ACRONYM_REPLACEMENTS:
        out = pattern.sub(spoken, out)
    return " ".join(out.split()).strip()
