"""Deterministic slot selection against last offered slots only."""

from voice.slot_selection import (
    is_new_availability_search_intent,
    recent_offered_slots_present,
    resolve_slot_selection,
)


def test_resolve_daypart_morning_first_in_bucket():
    state = {
        "exact_slots": [
            "2026-04-11T09:00:00-04:00",
            "2026-04-11T10:00:00-04:00",
        ],
        "suggested_slots": [],
    }
    r = resolve_slot_selection("can you book me for the morning", state)
    assert r.ok
    assert r.source == "daypart_bucket"
    assert "09:00:00" in (r.slot_iso or "")


def test_resolve_daypart_no_morning_slots():
    state = {
        "exact_slots": [
            "2026-04-11T13:00:00-04:00",
            "2026-04-11T14:00:00-04:00",
        ],
        "suggested_slots": [],
    }
    r = resolve_slot_selection("book me for the morning please", state)
    assert not r.ok


def test_resolve_time_against_offered_slots():
    state = {
        "exact_slots": ["2026-03-28T15:00:00-04:00", "2026-03-28T14:00:00-04:00"],
        "suggested_slots": [],
        "last_date_text": "tomorrow",
    }
    r = resolve_slot_selection("three pm", state)
    assert r.ok
    assert "15:00:00" in (r.slot_iso or "")


def test_resolve_ordinal_second():
    state = {
        "exact_slots": [
            "2026-03-28T14:00:00-04:00",
            "2026-03-28T15:00:00-04:00",
        ],
        "suggested_slots": [],
    }
    r = resolve_slot_selection("the second one", state)
    assert r.ok
    assert "15:00:00" in (r.slot_iso or "")


def test_recent_offered_slots_present():
    assert recent_offered_slots_present({"exact_slots": ["2026-03-28T15:00:00-04:00"], "suggested_slots": []})
    assert recent_offered_slots_present({"exact_slots": [], "suggested_slots": ["2026-03-28T15:00:00-04:00"]})
    assert not recent_offered_slots_present({"exact_slots": [], "suggested_slots": []})
    assert not recent_offered_slots_present({})


def test_new_search_skips_slot_resolution():
    assert is_new_availability_search_intent("can you check availability for another day") is True
    state = {"exact_slots": ["2026-03-28T15:00:00-04:00"], "suggested_slots": []}
    # Still resolves if we call resolve without gating — caller gates with is_new_availability_search_intent
    r = resolve_slot_selection("check another day", state)
    assert not r.ok


def test_do_you_have_time_is_new_availability_search_not_stale_slot_choice():
    assert is_new_availability_search_intent("do you have tomorrow at 2pm") is True
    assert is_new_availability_search_intent("what time do you have") is True
