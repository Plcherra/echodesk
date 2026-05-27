from __future__ import annotations

import logging
from datetime import datetime, timedelta

from ._parsing import get_free_slots, parse_datetime_range, parse_iso_datetime_or_natural

logger = logging.getLogger(__name__)

# Period buckets for summary_periods (hour ranges, inclusive start, exclusive end)
_PERIOD_HOURS = [
    ("morning", 6, 12),
    ("afternoon", 12, 17),
    ("evening", 17, 21),
]


def _slots_to_summary_periods(slots: list[str]) -> list[str]:
    """Return which periods (morning, afternoon, evening) have at least one slot."""
    seen: set[str] = set()
    for s in slots:
        try:
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
            h = dt.hour
            for name, lo, hi in _PERIOD_HOURS:
                if lo <= h < hi:
                    seen.add(name)
                    break
        except (ValueError, TypeError):
            pass
    return sorted(seen, key=lambda p: next(i for i, (n, _, _) in enumerate(_PERIOD_HOURS) if n == p))


def handle_check_availability(
    service,
    calendar_id: str,
    params: dict,
    *,
    default_timezone: str,
    default_slot_minutes: int,
    default_availability_slot_minutes: int,
    business_day_start_hour: int,
    business_day_end_hour: int,
    suggested_slots_max: int,
) -> dict:
    timezone = (params.get("timezone") or default_timezone).strip() or default_timezone
    date_text = params.get("date_text")
    start_date = params.get("start_date") or date_text
    end_date = params.get("end_date")

    if not start_date:
        return {"success": False, "error": "date_missing", "message": "Please provide a date and time (e.g. 'tomorrow at 4')."}

    range_data, parse_mode = parse_datetime_range(
        start_date,
        timezone=timezone,
        business_day_start_hour=business_day_start_hour,
        business_day_end_hour=business_day_end_hour,
    )
    if not range_data:
        return {"success": False, "error": "date_parse_failed", "message": "I couldn't understand the date/time. Could you rephrase it (e.g. 'March 17 at 7pm')?"}

    # Duration: for range-based queries default to 60 min for spoken availability; otherwise 30.
    range_modes = ("full_day", "range_morning", "range_afternoon", "range_evening")
    if parse_mode in range_modes:
        raw_dur = params.get("duration_minutes")
        if raw_dur is None or raw_dur == "":
            duration_minutes = default_availability_slot_minutes
        else:
            try:
                duration_minutes = int(raw_dur) if isinstance(raw_dur, str) else raw_dur
                duration_minutes = duration_minutes or default_availability_slot_minutes
            except (ValueError, TypeError):
                duration_minutes = default_availability_slot_minutes
    else:
        duration_minutes = params.get("duration_minutes") or default_slot_minutes
        if isinstance(duration_minutes, str):
            try:
                duration_minutes = int(duration_minutes) or default_slot_minutes
            except (ValueError, TypeError):
                duration_minutes = default_slot_minutes

    logger.info(
        "[CAL_DATE] check_availability input=%r timezone=%s mode=%s timeMin=%s timeMax=%s",
        start_date,
        timezone,
        parse_mode,
        range_data["timeMin"],
        range_data["timeMax"],
    )

    if end_date:
        try:
            end_d = datetime.fromisoformat(end_date.replace("Z", "+00:00"))
            range_data["timeMax"] = end_d.isoformat()
        except (ValueError, TypeError):
            pass

    logger.info(
        "[CALENDAR_CTX] availability_check calendar_id=%s timezone=%s timeMin=%s timeMax=%s",
        calendar_id,
        timezone,
        range_data["timeMin"],
        range_data["timeMax"],
    )

    freebusy = service.freebusy().query(
        body={
            "timeMin": range_data["timeMin"],
            "timeMax": range_data["timeMax"],
            "items": [{"id": calendar_id}],
        }
    ).execute()

    cal = freebusy.get("calendars", {}).get(calendar_id, {})
    busy = cal.get("busy") or []
    free_slots = get_free_slots(
        busy=busy,
        time_min=range_data["timeMin"],
        time_max=range_data["timeMax"],
        slot_minutes=duration_minutes,
    )

    requested_slot_start = None
    requested_slot_end = None
    slot_available = None
    available_slots: list[str] = []
    suggested_slots: list[str] = []
    requested_range_start: str | None = None
    requested_range_end: str | None = None

    exact_slots: list[str] = []
    summary_periods: list[str] = []

    if parse_mode in range_modes:
        requested_range_start = range_data["timeMin"]
        requested_range_end = range_data["timeMax"]
        available_slots = free_slots
        suggested_slots = free_slots[: min(suggested_slots_max, 3)]
        exact_slots = list(free_slots)
        summary_periods = _slots_to_summary_periods(free_slots)
        logger.info(
            "[CAL_DATE] range_slot_generation mode=%s range_start=%s range_end=%s duration_minutes=%s candidate_slots=%d returned_slots=%d",
            parse_mode,
            requested_range_start,
            requested_range_end,
            duration_minutes,
            len(free_slots),
            len(suggested_slots),
        )

    # For exact time requests (e.g. "tomorrow at 7pm"), check only that specific slot.
    if parse_mode == "exact_time_window":
        slot_start = parse_iso_datetime_or_natural(start_date, timezone=timezone)
        if slot_start:
            slot_end = slot_start + timedelta(minutes=duration_minutes)
            logger.info(
                "[CALENDAR_CTX] availability_slot_check calendar_id=%s slot_start=%s slot_end=%s",
                calendar_id,
                slot_start.isoformat(),
                slot_end.isoformat(),
            )
            slot_fb = service.freebusy().query(
                body={
                    "timeMin": slot_start.isoformat(),
                    "timeMax": slot_end.isoformat(),
                    "items": [{"id": calendar_id}],
                }
            ).execute()
            slot_cal = slot_fb.get("calendars", {}).get(calendar_id, {})
            slot_busy = slot_cal.get("busy") or []
            slot_available = len(slot_busy) == 0
            requested_slot_start = slot_start.isoformat()
            requested_slot_end = slot_end.isoformat()
            logger.info(
                "[CAL_DATE] check_availability_slot mode=exact_time_slot slot_start=%s slot_end=%s busy_count=%d",
                requested_slot_start,
                requested_slot_end,
                len(slot_busy),
            )
            if slot_available and requested_slot_start:
                exact_slots = [requested_slot_start]
                suggested_slots = [requested_slot_start]
                summary_periods = _slots_to_summary_periods(exact_slots)
            elif not slot_available:
                available_slots = free_slots
                suggested_slots = free_slots[: min(suggested_slots_max, 3)]
                exact_slots = list(free_slots)
                summary_periods = _slots_to_summary_periods(free_slots)

    return {
        "success": True,
        "free_slots": free_slots,
        "available_slots": available_slots,
        "suggested_slots": suggested_slots,
        "exact_slots": exact_slots,
        "summary_periods": summary_periods,
        "requested_range_start": requested_range_start,
        "requested_range_end": requested_range_end,
        "slot_duration_minutes": duration_minutes,
        "busy_slots": [{"start": b.get("start"), "end": b.get("end")} for b in busy],
        "requested_slot_start": requested_slot_start,
        "requested_slot_end": requested_slot_end,
        "slot_available": slot_available,
    }
