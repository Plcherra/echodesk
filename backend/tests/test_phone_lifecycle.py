"""Tests for pending-release / reclaim phone lifecycle helpers."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from telnyx.phone_lifecycle import (
    can_purchase_extra_number,
    expired_held_numbers,
    format_phone_display,
)


def test_format_phone_display_us():
    assert format_phone_display("+13105847719") == "+1 310-584-7719"
    assert format_phone_display("3105847719") == "+1 310-584-7719"


def test_format_phone_display_empty():
    assert format_phone_display(None) == ""
    assert format_phone_display("") == ""


def test_can_purchase_extra_only_when_one_held_and_no_live():
    held = [{"e164": "+13105550100", "live": False, "held_at": datetime.now(timezone.utc)}]
    assert can_purchase_extra_number(held) is True
    live = [{"e164": "+13105550100", "live": True, "held_at": None}]
    assert can_purchase_extra_number(live) is False
    two = [
        {"e164": "+13105550100", "live": False},
        {"e164": "+16175550100", "live": True},
    ]
    assert can_purchase_extra_number(two) is False
    assert can_purchase_extra_number([]) is False


def test_expired_held_skips_live_and_fresh():
    now = datetime(2026, 8, 12, 20, 0, tzinfo=timezone.utc)
    items = [
        {
            "e164": "+13105550111",
            "live": False,
            "held_at": now - timedelta(hours=49),
        },
        {
            "e164": "+13105550122",
            "live": False,
            "held_at": now - timedelta(hours=2),
        },
        {
            "e164": "+13105550133",
            "live": True,
            "held_at": now - timedelta(hours=80),
        },
    ]
    expired = expired_held_numbers(items, now=now, hold_hours=48)
    assert [i["e164"] for i in expired] == ["+13105550111"]
