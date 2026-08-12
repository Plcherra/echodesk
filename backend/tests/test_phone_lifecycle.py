"""Tests for pending-release / reclaim phone lifecycle helpers."""

from __future__ import annotations

from telnyx.phone_lifecycle import format_phone_display


def test_format_phone_display_us():
    assert format_phone_display("+13105847719") == "+1 310-584-7719"
    assert format_phone_display("3105847719") == "+1 310-584-7719"


def test_format_phone_display_empty():
    assert format_phone_display(None) == ""
    assert format_phone_display("") == ""
