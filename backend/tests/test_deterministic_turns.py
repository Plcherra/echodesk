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


def test_how_are_you_greeting_does_not_trigger_availability():
    # Regression: "how are you today" must not be read as a check_availability(today).
    result = _resolve("hi eve how are you today", use_calendar=True)

    assert result.handled is True
    assert result.tool_name is None
    assert result.reason == "smalltalk_greeting"
    assert "how can i help" in (result.reply or "").lower()


def test_short_greeting_opener_is_handled_without_llm():
    result = _resolve("hey there", use_calendar=True)

    assert result.handled is True
    assert result.tool_name is None
    assert result.reason == "smalltalk_greeting"


def test_greeting_with_real_booking_still_routes_to_calendar():
    # A booking cue overrides smalltalk: this must still reach the calendar fast path.
    result = _resolve("hi eve, what do you have tomorrow", use_calendar=True)

    assert result.handled is True
    assert result.tool_name == "check_availability"
    assert result.tool_args["date_text"] == "tomorrow"


def test_greeting_with_time_still_routes_to_calendar():
    result = _resolve("hi eve, do you have 9 AM", use_calendar=True)

    assert result.handled is True
    # time-without-date clarify path, not a smalltalk swallow
    assert result.reason == "clarify_time_without_date"
    assert result.tool_name is None


def test_daypart_narrowing_keeps_day_context_without_llm():
    # Regression: after offering "morning and afternoon" for tomorrow, saying "mornings"
    # must list the morning times for tomorrow — not re-ask for a specific day.
    state = {
        "exact_slots": [
            "2026-04-11T09:00:00-04:00",
            "2026-04-11T10:00:00-04:00",
            "2026-04-11T14:00:00-04:00",
        ],
        "suggested_slots": [],
        "summary_periods": ["morning", "afternoon"],
        "last_date_text": "tomorrow",
    }
    result = _resolve("mornings", use_calendar=True, offered_slots_state=state)

    assert result.handled is True
    assert result.tool_name is None
    assert result.reason == "daypart_narrowing"
    reply = (result.reply or "").lower()
    assert "tomorrow morning" in reply
    assert "9" in reply and "10" in reply
    assert "2" not in reply.split("which")[0]  # no afternoon 2pm slot listed


def test_daypart_narrowing_afternoon_lists_afternoon_slots():
    # Regression: "afternoons" must not go silent — same path as mornings.
    state = {
        "exact_slots": [
            "2026-04-11T09:00:00-04:00",
            "2026-04-11T14:00:00-04:00",
            "2026-04-11T15:00:00-04:00",
        ],
        "suggested_slots": [],
        "summary_periods": ["morning", "afternoon"],
        "last_date_text": "tomorrow",
    }
    result = _resolve("afternoons", use_calendar=True, offered_slots_state=state)

    assert result.handled is True
    assert result.reason == "daypart_narrowing"
    reply = (result.reply or "").lower()
    assert "tomorrow afternoon" in reply
    assert "2" in reply or "3" in reply or "14" in reply or "15" in reply


def test_daypart_narrowing_when_bucket_empty_steers_to_available():
    state = {
        "exact_slots": ["2026-04-11T14:00:00-04:00", "2026-04-11T15:00:00-04:00"],
        "suggested_slots": [],
        "summary_periods": ["afternoon"],
        "last_date_text": "tomorrow",
    }
    result = _resolve("mornings", use_calendar=True, offered_slots_state=state)

    assert result.handled is True
    assert result.reason == "daypart_narrowing"
    reply = (result.reply or "").lower()
    assert "don't have any morning" in reply
    assert "afternoon" in reply


def test_daypart_without_offered_slots_is_not_swallowed():
    # No prior availability offered → let normal routing/LLM handle it.
    result = _resolve("mornings", use_calendar=True, offered_slots_state={})

    assert result.reason != "daypart_narrowing"


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
