from voice.deterministic_turns import resolve_deterministic_turn
from voice.slot_selection import SlotResolution


def _resolve(text: str, **overrides):
    base = {
        "offered_slots_state": {},
        "use_calendar": False,
        "slot_pre_attempted": False,
        "last_slot_resolution": None,
        "last_assistant_text": "",
    }
    base.update(overrides)
    return resolve_deterministic_turn(text, **base)


def test_greeting_is_spoken_without_llm():
    result = _resolve("hi")

    assert result.handled is True
    assert result.reply == "Hi. How can I help?"
    assert result.tool_name is None
    assert result.requires_llm_fallback is False


def test_repeat_last_assistant_is_spoken_without_llm():
    result = _resolve(
        "can you repeat that",
        last_assistant_text="I found afternoon openings. Which time works best?",
    )

    assert result.handled is True
    assert "afternoon openings" in (result.reply or "")
    assert result.reason == "repeat_last_assistant"


def test_time_without_date_gets_clarifying_reply_not_bad_calendar_call():
    result = _resolve("do you have 9 AM", use_calendar=True)

    assert result.handled is True
    assert result.reply == "Sure — which day should I check for 9 am?"
    assert result.tool_name is None


def test_bare_hour_gets_clarifying_reply():
    result = _resolve("can you do 9", use_calendar=True)

    assert result.handled is True
    assert result.reply == "Sure — did you mean 9 AM or 9 PM, and which day?"
    assert result.tool_name is None


def test_calendar_availability_uses_tool_without_llm():
    result = _resolve("what do you have tomorrow", use_calendar=True)

    assert result.handled is True
    assert result.tool_name == "check_availability"
    assert result.tool_args["date_text"] == "tomorrow"
    assert result.reason == "calendar_check_availability"


def test_slot_selection_uses_create_appointment_without_llm():
    slot = "2026-04-11T13:00:00-04:00"
    result = _resolve(
        "the first one",
        use_calendar=True,
        offered_slots_state={"exact_slots": [slot], "suggested_slots": [], "last_date_text": "tomorrow"},
        slot_pre_attempted=True,
        last_slot_resolution=SlotResolution(True, slot, "ordinal", ambiguous=False),
    )

    assert result.handled is True
    assert result.tool_name == "create_appointment"
    assert result.tool_args["start_time"] == slot
    assert result.reason == "calendar_create_appointment"
