from api.mobile_routes import _has_recording_ai_consent


def test_receptionist_create_requires_explicit_consent():
    assert _has_recording_ai_consent({}) is False
    assert _has_recording_ai_consent({"consent": False}) is False
    assert _has_recording_ai_consent({"consent": "false"}) is False


def test_receptionist_create_accepts_truthy_consent():
    assert _has_recording_ai_consent({"consent": True}) is True
    assert _has_recording_ai_consent({"consent": "true"}) is True
    assert _has_recording_ai_consent({"consent": "1"}) is True
