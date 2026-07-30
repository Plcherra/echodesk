"""Tests for internal ops notify helpers."""

from unittest.mock import MagicMock, patch

from utils.internal_notify import notify_phone_number_release_needed


def test_notify_logs_and_skips_email_without_api_key(monkeypatch):
    monkeypatch.setattr("utils.internal_notify.settings.resend_api_key", "")
    monkeypatch.setattr(
        "utils.internal_notify.settings.support_email", "echodesk2@gmail.com"
    )
    with patch("utils.internal_notify.httpx.Client") as client_cls:
        ok = notify_phone_number_release_needed(
            receptionist_id="rec-1",
            receptionist_name="Eve",
            phone_number="+15551234567",
            telnyx_phone_number_id="PN123",
            owner_user_id="user-1",
            owner_email="owner@example.com",
            business_id="biz-1",
        )
    assert ok is False
    client_cls.assert_not_called()


def test_notify_sends_resend_email_when_configured(monkeypatch):
    monkeypatch.setattr("utils.internal_notify.settings.resend_api_key", "re_test")
    monkeypatch.setattr(
        "utils.internal_notify.settings.support_email", "echodesk2@gmail.com"
    )
    monkeypatch.setattr(
        "utils.internal_notify.settings.email_from",
        "EchoDesk <noreply@echodesk.us>",
    )

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.text = '{"id":"email_1"}'
    mock_client = MagicMock()
    mock_client.__enter__.return_value = mock_client
    mock_client.__exit__.return_value = False
    mock_client.post.return_value = mock_resp

    with patch("utils.internal_notify.httpx.Client", return_value=mock_client):
        ok = notify_phone_number_release_needed(
            receptionist_id="rec-1",
            receptionist_name="Eve",
            phone_number="+15551234567",
            telnyx_phone_number_id="PN123",
            owner_user_id="user-1",
            owner_email="owner@example.com",
            business_id="biz-1",
        )

    assert ok is True
    mock_client.post.assert_called_once()
    args, kwargs = mock_client.post.call_args
    assert args[0] == "https://api.resend.com/emails"
    assert kwargs["headers"]["Authorization"] == "Bearer re_test"
    assert kwargs["json"]["to"] == ["echodesk2@gmail.com"]
    assert "+15551234567" in kwargs["json"]["subject"]
    assert "PN123" in kwargs["json"]["text"]
