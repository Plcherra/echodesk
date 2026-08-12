"""Tests for internal ops notify helpers."""

from unittest.mock import MagicMock, patch

from utils.internal_notify import (
    notify_customer_number_released,
    notify_number_transfer_requested,
    notify_phone_number_release_needed,
)


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


def test_notify_transfer_requested_includes_kind_and_carrier(monkeypatch):
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
    mock_resp.text = '{"id":"email_2"}'
    mock_client = MagicMock()
    mock_client.__enter__.return_value = mock_client
    mock_client.__exit__.return_value = False
    mock_client.post.return_value = mock_resp

    with patch("utils.internal_notify.httpx.Client", return_value=mock_client):
        ok = notify_number_transfer_requested(
            request_id="req-1",
            phone_number="+15559876543",
            number_kind="mobile_carrier",
            carrier_or_provider="T-Mobile",
            customer_note="Keep my cell",
            owner_user_id="user-1",
            owner_email="owner@example.com",
            business_id=None,
        )

    assert ok is True
    text = mock_client.post.call_args.kwargs["json"]["text"]
    assert "T-Mobile" in text
    assert "mobile_carrier" in text
    assert "req-1" in text
    assert "completed" in text
    assert "rejected" in text


def test_notify_customer_number_released_emails_owner(monkeypatch):
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
    mock_resp.text = '{"id":"email_3"}'
    mock_client = MagicMock()
    mock_client.__enter__.return_value = mock_client
    mock_client.__exit__.return_value = False
    mock_client.post.return_value = mock_resp

    with patch("utils.internal_notify.httpx.Client", return_value=mock_client):
        ok = notify_customer_number_released(
            owner_email="owner@example.com",
            phone_number="+16174999456",
        )

    assert ok is True
    payload = mock_client.post.call_args.kwargs["json"]
    assert payload["to"] == ["owner@example.com"]
    assert "+16174999456" in payload["text"]
    assert "released" in payload["subject"].lower()


def test_release_needed_email_includes_mark_released_api(monkeypatch):
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
    mock_client = MagicMock()
    mock_client.__enter__.return_value = mock_client
    mock_client.__exit__.return_value = False
    mock_client.post.return_value = mock_resp

    with patch("utils.internal_notify.httpx.Client", return_value=mock_client):
        notify_phone_number_release_needed(
            receptionist_id="rec-1",
            receptionist_name="Eve",
            phone_number="+15551234567",
            telnyx_phone_number_id="PN123",
            owner_user_id="user-1",
            owner_email="owner@example.com",
            business_id="biz-1",
        )

    text = mock_client.post.call_args.kwargs["json"]["text"]
    assert "/api/internal/phone-numbers/release" in text
    assert "PN123" in text
