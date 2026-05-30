"""Unit tests for extracted pipeline transcript/template helpers (behavior lock for refactors)."""

from __future__ import annotations

import json

import pytest

from voice import pipeline_templates, pipeline_transcript


def test_passes_transcript_guard_whitelist_and_filler():
    assert pipeline_transcript.passes_transcript_guard("hello") is True
    assert pipeline_transcript.passes_transcript_guard("um") is False
    assert pipeline_transcript.passes_transcript_guard("book something tomorrow") is True


def test_is_booking_confirmation_requires_time_and_booking_phrase():
    assert pipeline_transcript.is_booking_confirmation_intent("book me at 3pm") is True
    assert pipeline_transcript.is_booking_confirmation_intent("book me") is False


def test_contains_clear_intent_post_booking_phrase():
    assert pipeline_transcript.contains_clear_intent("is there anything else I should know") is True


def test_contains_clear_intent_time_availability_question():
    assert pipeline_transcript.contains_clear_intent("Do you have nine AM?") is True


@pytest.mark.parametrize(
    "text",
    [
        "do you have tomorrow morning",
        "can you do 9",
        "book that",
        "the first one",
        "yes that works",
    ],
)
def test_contains_clear_intent_immediate_turn_patterns(text: str):
    assert pipeline_transcript.contains_clear_intent(text) is True


@pytest.mark.parametrize("text", ["can you", "tomorrow at", "I need"])
def test_incomplete_transcript_still_waits(text: str):
    assert pipeline_transcript.is_incomplete_transcript(text) is True


def test_is_farewell_courtesy_intent():
    assert pipeline_transcript.is_farewell_courtesy_intent("Thank you. Have a great night.") is True
    assert pipeline_transcript.is_farewell_courtesy_intent("good morning") is False
    assert pipeline_transcript.is_farewell_courtesy_intent("bye") is True


def test_template_create_appointment_success_includes_spoken_time():
    payload = json.dumps({"success": True, "start_time": "2026-03-17T15:00:00+00:00"})
    out = pipeline_templates.template_from_tool_result(
        "create_appointment",
        payload,
        requested_date="tomorrow",
        requested_time=None,
        voice_session={},
    )
    assert out and "all set" in out.lower()


def test_template_check_availability_failure_fixed_copy():
    payload = json.dumps({"success": False})
    out = pipeline_templates.template_from_tool_result(
        "check_availability",
        payload,
        requested_date=None,
        requested_time=None,
        voice_session=None,
    )
    assert out and "couldn't fetch availability" in out.lower()


def test_template_check_availability_success_bucket_then_times():
    payload = json.dumps(
        {
            "success": True,
            "suggested_slots": [
                "2026-04-11T13:00:00-04:00",
                "2026-04-11T14:00:00-04:00",
                "2026-04-11T15:00:00-04:00",
            ],
            "summary_periods": ["afternoon"],
        }
    )
    out = pipeline_templates.template_from_tool_result(
        "check_availability",
        payload,
        requested_date="tomorrow",
        requested_time=None,
        voice_session=None,
    )
    assert out
    assert "afternoon openings" in out.lower()
    assert "which time works best" in out.lower()


def test_template_check_availability_exact_time_available_answers_yes():
    payload = json.dumps(
        {
            "success": True,
            "slot_available": True,
            "exact_slots": ["2026-04-11T14:00:00-04:00"],
            "suggested_slots": ["2026-04-11T14:00:00-04:00"],
        }
    )
    out = pipeline_templates.template_from_tool_result(
        "check_availability",
        payload,
        requested_date="tomorrow",
        requested_time="2 pm",
        voice_session=None,
    )
    assert out
    assert "yes" in out.lower()
    assert "2 pm tomorrow is available" in out.lower()


def test_template_check_availability_list_exact_times_when_requested():
    payload = json.dumps(
        {
            "success": True,
            "exact_slots": [
                "2026-04-11T09:00:00-04:00",
                "2026-04-11T10:00:00-04:00",
                "2026-04-11T11:00:00-04:00",
                "2026-04-11T12:00:00-04:00",
            ],
            "suggested_slots": [
                "2026-04-11T09:00:00-04:00",
                "2026-04-11T10:00:00-04:00",
                "2026-04-11T11:00:00-04:00",
            ],
            "summary_periods": ["morning", "afternoon"],
        }
    )
    out = pipeline_templates.template_from_tool_result(
        "check_availability",
        payload,
        requested_date="tomorrow",
        requested_time=None,
        voice_session=None,
        list_exact_times=True,
    )
    assert out
    assert "9:00 am" in out.lower()
    assert "10:00 am" in out.lower()
    assert "11:00 am" in out.lower()


def test_unavailable_requested_time_reply_uses_last_periods():
    out = pipeline_templates.unavailable_requested_time_reply(
        "9 am",
        {
            "exact_slots": [
                "2026-04-11T13:00:00-04:00",
                "2026-04-11T18:00:00-04:00",
            ],
            "suggested_slots": [],
            "summary_periods": ["afternoon", "evening"],
        },
    )
    assert "9 am" in out.lower()
    assert "afternoon and evening openings" in out.lower()


@pytest.mark.parametrize(
    "sms,expected_substr",
    [
        ({}, ""),
        ({"attempted": True, "api_accepted": False}, "wasn't able to send"),
        ({"attempted": True, "api_accepted": True, "telnyx_message_id": ""}, "messaging delivery"),
    ],
)
def test_truth_aware_sms_line_api_layer(sms: dict, expected_substr: str):
    line = pipeline_templates.truth_aware_sms_line({"sms": sms})
    if not expected_substr:
        assert line == ""
    else:
        assert expected_substr in line.lower()
