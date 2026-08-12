"""Weekly bookable hours + closed-date helpers for scheduling."""

from __future__ import annotations

from datetime import date, datetime, time, timedelta
from typing import Any, Optional

WEEKDAY_KEYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
WEEKDAY_LABELS = {
    "mon": "Monday",
    "tue": "Tuesday",
    "wed": "Wednesday",
    "thu": "Thursday",
    "fri": "Friday",
    "sat": "Saturday",
    "sun": "Sunday",
}

# Fallback when receptionist has no structured hours yet (legacy rows).
DEFAULT_WEEKLY: dict[str, dict[str, Any]] = {
    "mon": {"open": True, "start": "09:00", "end": "17:00"},
    "tue": {"open": True, "start": "09:00", "end": "17:00"},
    "wed": {"open": True, "start": "09:00", "end": "17:00"},
    "thu": {"open": True, "start": "09:00", "end": "17:00"},
    "fri": {"open": True, "start": "09:00", "end": "17:00"},
    "sat": {"open": False, "start": "09:00", "end": "17:00"},
    "sun": {"open": False, "start": "09:00", "end": "17:00"},
}

_PERIOD_WINDOWS = {
    "morning": (time(6, 0), time(12, 0)),
    "afternoon": (time(12, 0), time(17, 0)),
    "evening": (time(17, 0), time(21, 0)),
}


def weekday_key(d: date) -> str:
    return WEEKDAY_KEYS[d.weekday()]


def parse_hhmm(value: str) -> Optional[time]:
    raw = (value or "").strip()
    if not raw:
        return None
    parts = raw.split(":")
    if len(parts) < 2:
        return None
    try:
        h = int(parts[0])
        m = int(parts[1])
    except (TypeError, ValueError):
        return None
    if h < 0 or h > 23 or m < 0 or m > 59:
        return None
    return time(h, m)


def normalize_bookable_hours(raw: Any) -> Optional[dict[str, Any]]:
    """Validate and normalize weekly hours. Returns None if invalid."""
    if not isinstance(raw, dict):
        return None
    weekly_in = raw.get("weekly") if isinstance(raw.get("weekly"), dict) else raw
    if not isinstance(weekly_in, dict):
        return None

    weekly: dict[str, dict[str, Any]] = {}
    open_count = 0
    for key in WEEKDAY_KEYS:
        day = weekly_in.get(key)
        if not isinstance(day, dict):
            return None
        is_open = bool(day.get("open"))
        start_s = str(day.get("start") or "").strip()
        end_s = str(day.get("end") or "").strip()
        start_t = parse_hhmm(start_s)
        end_t = parse_hhmm(end_s)
        if is_open:
            if start_t is None or end_t is None:
                return None
            # Allow overnight (end <= start) and same-day windows; reject identical
            # start/end only when that would mean a zero-length same-day window —
            # treat 00:00–00:00 as 24h open (overnight full cycle).
            open_count += 1
        else:
            # Closed days still store defaults for easier editing later.
            if start_t is None:
                start_s = "09:00"
            else:
                start_s = f"{start_t.hour:02d}:{start_t.minute:02d}"
            if end_t is None:
                end_s = "17:00"
            else:
                end_s = f"{end_t.hour:02d}:{end_t.minute:02d}"
            start_t = parse_hhmm(start_s)
            end_t = parse_hhmm(end_s)

        assert start_t is not None and end_t is not None
        weekly[key] = {
            "open": is_open,
            "start": f"{start_t.hour:02d}:{start_t.minute:02d}",
            "end": f"{end_t.hour:02d}:{end_t.minute:02d}",
        }

    if open_count < 1:
        return None
    return {"weekly": weekly}


def default_bookable_hours() -> dict[str, Any]:
    return {"weekly": {k: dict(v) for k, v in DEFAULT_WEEKLY.items()}}


def effective_weekly(bookable_hours: Any) -> dict[str, dict[str, Any]]:
    normalized = normalize_bookable_hours(bookable_hours)
    if normalized:
        return normalized["weekly"]
    return {k: dict(v) for k, v in DEFAULT_WEEKLY.items()}


def format_bookable_hours_for_prompt(bookable_hours: Any) -> str:
    weekly = effective_weekly(bookable_hours)
    parts: list[str] = []
    for key in WEEKDAY_KEYS:
        day = weekly[key]
        label = WEEKDAY_LABELS[key]
        if not day.get("open"):
            parts.append(f"{label}: closed")
            continue
        start = day.get("start", "09:00")
        end = day.get("end", "17:00")
        if parse_hhmm(start) and parse_hhmm(end) and parse_hhmm(end) <= parse_hhmm(start):
            parts.append(f"{label}: {start}–{end} (overnight)")
        else:
            parts.append(f"{label}: {start}–{end}")
    return "Bookable hours (local): " + "; ".join(parts) + "."


def is_closed_on(closed_dates: set[date] | list[date] | None, d: date) -> bool:
    if not closed_dates:
        return False
    return d in set(closed_dates)


def day_window(
    bookable_hours: Any,
    d: date,
    *,
    closed_dates: set[date] | list[date] | None = None,
) -> Optional[tuple[datetime, datetime]]:
    """Return local naive start/end datetimes for bookable slots on date d, or None if closed."""
    if is_closed_on(closed_dates, d):
        return None
    weekly = effective_weekly(bookable_hours)
    day = weekly.get(weekday_key(d)) or {}
    if not day.get("open"):
        return None
    start_t = parse_hhmm(str(day.get("start") or ""))
    end_t = parse_hhmm(str(day.get("end") or ""))
    if start_t is None or end_t is None:
        return None
    start_dt = datetime.combine(d, start_t)
    end_dt = datetime.combine(d, end_t)
    if end_t <= start_t:
        # Overnight or 24h (00:00–00:00): ends next calendar day.
        end_dt = end_dt + timedelta(days=1)
    if end_dt <= start_dt:
        return None
    return start_dt, end_dt


def intersect_period_with_day(
    day_start: datetime,
    day_end: datetime,
    period: str,
) -> Optional[tuple[datetime, datetime]]:
    """Clip morning/afternoon/evening buckets to the day's bookable window."""
    bounds = _PERIOD_WINDOWS.get(period)
    if not bounds:
        return day_start, day_end
    p_start, p_end = bounds
    # Period is same calendar day as day_start (overnight day_end may be next day).
    base = day_start.date()
    period_start = datetime.combine(base, p_start)
    period_end = datetime.combine(base, p_end)
    start = max(day_start, period_start)
    end = min(day_end, period_end)
    if end <= start:
        return None
    return start, end


def apply_bookable_window_to_range(
    *,
    range_data: dict[str, str],
    parse_mode: str,
    bookable_hours: Any,
    closed_dates: set[date] | list[date] | None,
    timezone_name: str,
) -> tuple[dict[str, str] | None, str | None]:
    """
    Constrain a parsed availability range to structured bookable hours.

    Returns (range_data, error_code). error_code is 'closed' or 'no_hours' when unavailable.
    """
    _ = timezone_name  # reserved: windows are already local-naive / ISO from parser
    try:
        anchor = datetime.fromisoformat(range_data["timeMin"].replace("Z", "+00:00"))
    except (ValueError, TypeError, KeyError):
        return range_data, None

    local_day = anchor.date()
    window = day_window(bookable_hours, local_day, closed_dates=closed_dates)
    if window is None:
        return None, "closed"

    day_start, day_end = window
    period = None
    if parse_mode.startswith("range_"):
        period = parse_mode.replace("range_", "", 1)

    if parse_mode == "full_day" or period:
        if period:
            clipped = intersect_period_with_day(day_start, day_end, period)
            if clipped is None:
                return None, "no_hours"
            start_dt, end_dt = clipped
        else:
            start_dt, end_dt = day_start, day_end
        # Preserve timezone awareness from original parse when present.
        if anchor.tzinfo is not None:
            start_dt = start_dt.replace(tzinfo=anchor.tzinfo)
            end_dt = end_dt.replace(tzinfo=anchor.tzinfo)
        return {"timeMin": start_dt.isoformat(), "timeMax": end_dt.isoformat()}, None

    # Exact / explicit time windows: keep requested start, but still reject closed days.
    return range_data, None


def slot_within_bookable_hours(
    slot_iso: str,
    bookable_hours: Any,
    *,
    closed_dates: set[date] | list[date] | None = None,
) -> bool:
    try:
        dt = datetime.fromisoformat(slot_iso.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return False
    local_day = dt.date()
    window = day_window(bookable_hours, local_day, closed_dates=closed_dates)
    if window is None:
        # Overnight from previous day: check yesterday's window.
        prev = local_day - timedelta(days=1)
        window = day_window(bookable_hours, prev, closed_dates=closed_dates)
        if window is None:
            return False
    start_dt, end_dt = window
    naive = dt.replace(tzinfo=None) if dt.tzinfo else dt
    return start_dt <= naive < end_dt
