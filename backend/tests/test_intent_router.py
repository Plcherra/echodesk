"""Calendar fast-path routing (no Grok)."""

from voice.intent_router import resolve_calendar_fast_path


def test_availability_phrasing_goes_to_grok():
    d = resolve_calendar_fast_path(
        "what do you have tomorrow",
        {},
        slot_pre_attempted=False,
        last_slot_resolution=None,
    )
    assert d.fast_tool_name is None
    assert d.slot_fast is False


def test_any_time_tomorrow_goes_to_grok():
    d = resolve_calendar_fast_path(
        "do you have any time tomorrow",
        {},
        slot_pre_attempted=False,
        last_slot_resolution=None,
    )
    assert d.fast_tool_name is None


def test_do_you_have_tomorrow_at_time_goes_to_grok_not_stale_slot():
    d = resolve_calendar_fast_path(
        "do you have tomorrow at 2pm",
        {"exact_slots": ["2026-04-11T15:00:00-04:00"], "suggested_slots": []},
        slot_pre_attempted=False,
        last_slot_resolution=None,
    )
    assert d.fast_tool_name is None


def test_fast_path_create_from_slot_resolution():
    from voice.slot_selection import SlotResolution

    sr = SlotResolution(True, "2026-04-11T13:00:00-04:00", "exact_time_match", ambiguous=False)
    state = {
        "exact_slots": ["2026-04-11T13:00:00-04:00"],
        "suggested_slots": [],
        "last_date_text": "tomorrow",
    }
    d = resolve_calendar_fast_path(
        "one pm please",
        state,
        slot_pre_attempted=True,
        last_slot_resolution=sr,
    )
    assert d.fast_tool_name == "create_appointment"
    assert d.fast_tool_args.get("start_time") == "2026-04-11T13:00:00-04:00"
