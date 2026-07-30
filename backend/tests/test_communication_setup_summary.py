"""Communication setup summary tests."""

from __future__ import annotations

from communication.setup_summary import build_setup_summary


def _business() -> dict:
    return {
        "id": "biz_1",
        "name": "Test Business",
        "mode": "solo",
    }


def test_setup_summary_starts_with_voice_setup_when_no_number() -> None:
    summary = build_setup_summary(
        _business(),
        {"status": "not_started"},
        {"status": "not_started"},
        {"status": "not_connected"},
        is_default_business=True,
    )

    assert summary["voice_status"] == "not_started"
    assert summary["next_recommended_action"] == "create_receptionist"
    assert summary["voice_primary_action"] == "Create receptionist"


def test_setup_summary_surfaces_failed_voice_retry_before_sms() -> None:
    summary = build_setup_summary(
        _business(),
        {"status": "failed"},
        {"status": "not_started"},
        {"status": "not_connected"},
        is_default_business=True,
    )

    assert summary["voice_status"] == "failed"
    assert summary["next_recommended_action"] == "create_receptionist"
    assert summary["voice_primary_action"] == "Retry phone setup"


def test_setup_summary_allows_sms_after_voice_active() -> None:
    summary = build_setup_summary(
        _business(),
        {
            "status": "active",
            "phone_number_e164": "+15551234567",
            "telnyx_number_id": "123",
        },
        {"status": "not_started"},
        {"status": "not_connected"},
        is_default_business=True,
    )

    assert summary["voice_status"] == "active"
    assert summary["next_recommended_action"] == "activate_sms"


def test_setup_summary_treats_provisioning_with_number_as_active() -> None:
    summary = build_setup_summary(
        _business(),
        {
            "status": "provisioning",
            "phone_number_e164": "+15551234567",
            "telnyx_number_id": "123",
        },
        {"status": "not_started"},
        {"status": "not_connected"},
        is_default_business=True,
    )

    assert summary["voice_status"] == "active"
    assert summary["voice_setup_title"] == "Business line ready"
    assert summary["voice_primary_action"] == ""
