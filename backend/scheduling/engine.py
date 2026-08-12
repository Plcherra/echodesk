"""Unified scheduling entrypoints (Phase 1: wrap calendar_api; Google sync only)."""

from __future__ import annotations

from typing import Any, Callable

from calendar_api._availability import handle_check_availability
from calendar_api._booking import handle_create_appointment, handle_reschedule


def check_availability(
    service: Any,
    calendar_id: str,
    params: dict,
    *,
    default_timezone: str,
    default_slot_minutes: int,
    default_availability_slot_minutes: int,
    business_day_start_hour: int,
    business_day_end_hour: int,
    suggested_slots_max: int,
    staff_id: str | None = None,
    bookable_hours: Any = None,
    closed_dates: Any = None,
) -> dict:
    _ = staff_id  # Reserved for multi-staff calendars (Phase 2).
    return handle_check_availability(
        service,
        calendar_id,
        params,
        default_timezone=default_timezone,
        default_slot_minutes=default_slot_minutes,
        default_availability_slot_minutes=default_availability_slot_minutes,
        business_day_start_hour=business_day_start_hour,
        business_day_end_hour=business_day_end_hour,
        suggested_slots_max=suggested_slots_max,
        bookable_hours=bookable_hours,
        closed_dates=closed_dates,
    )


def create_booking(
    service: Any,
    calendar_id: str,
    params: dict,
    receptionist_id: str,
    supabase: Any,
    *,
    default_timezone: str,
    default_slot_minutes: int,
    call_control_id: str | None = None,
    staff_id: str | None = None,
) -> dict:
    _ = staff_id  # Reserved for multi-staff calendars (Phase 2).
    return handle_create_appointment(
        service,
        calendar_id,
        params,
        receptionist_id=receptionist_id,
        supabase=supabase,
        default_timezone=default_timezone,
        default_slot_minutes=default_slot_minutes,
        call_control_id=call_control_id,
    )


def reschedule_booking(
    service: Any,
    calendar_id: str,
    params: dict,
    *,
    default_timezone: str,
    default_slot_minutes: int,
    parse_datetime_range_fn: Callable[..., Any],
    receptionist_id: str | None = None,
    supabase: Any | None = None,
    staff_id: str | None = None,
) -> dict:
    _ = staff_id  # Reserved for multi-staff calendars (Phase 2).
    return handle_reschedule(
        service,
        calendar_id,
        params,
        default_timezone=default_timezone,
        default_slot_minutes=default_slot_minutes,
        parse_datetime_range_fn=parse_datetime_range_fn,
        receptionist_id=receptionist_id,
        supabase=supabase,
    )
