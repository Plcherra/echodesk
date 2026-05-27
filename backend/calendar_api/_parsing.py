from __future__ import annotations

from datetime import datetime, timedelta

from utils.natural_datetime import parse_natural_datetime


def parse_datetime_range(
    date_str: str,
    *,
    timezone: str,
    business_day_start_hour: int,
    business_day_end_hour: int,
) -> tuple[dict[str, str] | None, str]:
    """
    Parse either an ISO datetime/date or a natural language date into a timeMin/timeMax range.

    - If the input includes an explicit time (or is ISO datetime), use a 24h window from that moment.
    - If the input is date-only or natural language without explicit time, use the whole local day.
    """
    raw = (date_str or "").strip()
    if not raw:
        return None, "invalid"

    # First, try ISO.
    try:
        d = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        time_min = d.isoformat()
        time_max = (d + timedelta(days=1)).isoformat()
        mode = "exact_time_window" if ("T" in raw or ":" in raw or " " in raw) else "full_day"
        return {"timeMin": time_min, "timeMax": time_max}, mode
    except (ValueError, TypeError):
        pass

    parsed = parse_natural_datetime(raw, timezone=timezone)
    if not parsed:
        return None, "invalid"

    d = parsed.dt
    t = raw.lower()
    period = None
    if "morning" in t:
        period = "morning"
        day_start = d.replace(hour=9, minute=0, second=0, microsecond=0)
        day_end = d.replace(hour=12, minute=0, second=0, microsecond=0)
    elif "afternoon" in t:
        period = "afternoon"
        day_start = d.replace(hour=12, minute=0, second=0, microsecond=0)
        day_end = d.replace(hour=17, minute=0, second=0, microsecond=0)
    elif "evening" in t:
        period = "evening"
        day_start = d.replace(hour=17, minute=0, second=0, microsecond=0)
        day_end = d.replace(hour=20, minute=0, second=0, microsecond=0)
    else:
        period = None

    if period:
        mode = f"range_{period}"
        return {"timeMin": day_start.isoformat(), "timeMax": day_end.isoformat()}, mode

    if parsed.is_time_explicit:
        time_min = d.isoformat()
        time_max = (d + timedelta(days=1)).isoformat()
        return {"timeMin": time_min, "timeMax": time_max}, "exact_time_window"

    # Full day: business hours for bookable slot suggestions.
    day_start = d.replace(hour=business_day_start_hour, minute=0, second=0, microsecond=0)
    day_end = d.replace(hour=business_day_end_hour, minute=0, second=0, microsecond=0)
    return {"timeMin": day_start.isoformat(), "timeMax": day_end.isoformat()}, "full_day"


def parse_iso_datetime_or_natural(date_str: str, *, timezone: str) -> datetime | None:
    """Parse ISO datetime or natural language datetime into an aware datetime."""
    raw = (date_str or "").strip()
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        parsed = parse_natural_datetime(raw, timezone=timezone)
        return parsed.dt if parsed else None


def get_free_slots(
    *,
    busy: list[dict],
    time_min: str,
    time_max: str,
    slot_minutes: int,
) -> list[str]:
    slot_ms = slot_minutes * 60 * 1000
    try:
        min_dt = datetime.fromisoformat(time_min.replace("Z", "+00:00"))
        max_dt = datetime.fromisoformat(time_max.replace("Z", "+00:00"))
        min_ts = min_dt.timestamp() * 1000
        max_ts = max_dt.timestamp() * 1000
    except (ValueError, TypeError):
        return []

    busy_ranges = []
    for b in busy:
        start = b.get("start")
        end = b.get("end")
        if start and end:
            try:
                s = datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp() * 1000
                e = datetime.fromisoformat(end.replace("Z", "+00:00")).timestamp() * 1000
                busy_ranges.append((s, e))
            except (ValueError, TypeError):
                pass
    busy_ranges.sort(key=lambda x: x[0])

    slots = []
    t = min_ts
    while t + slot_ms <= max_ts:
        slot_end = t + slot_ms
        overlaps = any(
            (t >= r[0] and t < r[1]) or (slot_end > r[0] and slot_end <= r[1]) or (t <= r[0] and slot_end >= r[1])
            for r in busy_ranges
        )
        if not overlaps:
            slots.append(datetime.fromtimestamp(t / 1000, tz=min_dt.tzinfo).isoformat())
        t = slot_end
    return slots
