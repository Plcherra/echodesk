"""Tests for structured bookable hours + closed-date helpers."""

from __future__ import annotations

from datetime import date, datetime

from scheduling.bookable_hours import (
    apply_bookable_window_to_range,
    day_window,
    default_bookable_hours,
    format_bookable_hours_for_prompt,
    normalize_bookable_hours,
    slot_within_bookable_hours,
)


def test_normalize_requires_at_least_one_open_day():
    raw = default_bookable_hours()
    for key in raw["weekly"]:
        raw["weekly"][key]["open"] = False
    assert normalize_bookable_hours(raw) is None


def test_normalize_accepts_overnight():
    raw = default_bookable_hours()
    raw["weekly"]["fri"] = {"open": True, "start": "22:00", "end": "06:00"}
    out = normalize_bookable_hours(raw)
    assert out is not None
    assert out["weekly"]["fri"]["start"] == "22:00"
    assert out["weekly"]["fri"]["end"] == "06:00"


def test_day_window_closed_weekly_and_exception():
    hours = default_bookable_hours()
    # Sunday closed by default
    assert day_window(hours, date(2026, 4, 12)) is None  # Sunday
    # Monday open
    win = day_window(hours, date(2026, 4, 13))
    assert win is not None
    assert win[0] == datetime(2026, 4, 13, 9, 0)
    assert win[1] == datetime(2026, 4, 13, 17, 0)
    # Holiday override on Monday
    assert day_window(hours, date(2026, 4, 13), closed_dates={date(2026, 4, 13)}) is None


def test_apply_full_day_uses_bookable_window():
    hours = default_bookable_hours()
    hours["weekly"]["mon"] = {"open": True, "start": "10:00", "end": "14:00"}
    range_data = {
        "timeMin": "2026-04-13T00:00:00-04:00",
        "timeMax": "2026-04-13T23:59:00-04:00",
    }
    out, err = apply_bookable_window_to_range(
        range_data=range_data,
        parse_mode="full_day",
        bookable_hours=hours,
        closed_dates=None,
        timezone_name="America/New_York",
    )
    assert err is None
    assert out is not None
    assert "10:00" in out["timeMin"]
    assert "14:00" in out["timeMax"]


def test_apply_closed_day_returns_closed():
    hours = default_bookable_hours()
    range_data = {
        "timeMin": "2026-04-12T00:00:00-04:00",
        "timeMax": "2026-04-12T23:59:00-04:00",
    }
    out, err = apply_bookable_window_to_range(
        range_data=range_data,
        parse_mode="full_day",
        bookable_hours=hours,
        closed_dates=None,
        timezone_name="America/New_York",
    )
    assert out is None
    assert err == "closed"


def test_slot_within_bookable_hours():
    hours = default_bookable_hours()
    assert slot_within_bookable_hours("2026-04-13T11:00:00", hours) is True
    assert slot_within_bookable_hours("2026-04-13T18:00:00", hours) is False
    assert slot_within_bookable_hours("2026-04-12T11:00:00", hours) is False


def test_prompt_format_includes_days():
    text = format_bookable_hours_for_prompt(default_bookable_hours())
    assert "Monday: 09:00–17:00" in text
    assert "Sunday: closed" in text
