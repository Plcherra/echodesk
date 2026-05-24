from communication.sms_onboarding import _default_registration_profile


def test_default_registration_profile_is_business_sender_not_platform_sender():
    profile = _default_registration_profile(
        {"email": "owner@example.com", "business_name": "Pedro Studio"},
        {"name": "Pedro Studio"},
        None,
    )

    assert "EchoDesk as a shared sender" in profile["message_flow"]
    assert "Pedro Studio" in profile["description"]
    assert "Reply STOP" in profile["sample1"]
    assert "HELP" in profile["sample2"]
