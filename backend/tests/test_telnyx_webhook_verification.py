"""Integration tests for Telnyx voice webhook verification."""

from __future__ import annotations

import base64
import hmac
import hashlib
import time
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

# Import after conftest sets env (app will validate at lifespan)
from main import app

# Sample call.initiated payload
SAMPLE_PAYLOAD = {
    "data": {
        "event_type": "call.initiated",
        "id": "webhook-id-123",
        "payload": {
            "call_control_id": "call-ctrl-456",
            "to": "+15551234567",
            "from": "+15559876543",
        },
    }
}

SAMPLE_JSON = '{"data":{"event_type":"call.initiated","id":"webhook-id-123","payload":{"call_control_id":"call-ctrl-456","to":"+15551234567","from":"+15559876543"}}}'


def _make_hmac_signature(payload: bytes, secret: str) -> str:
    """Create valid HMAC signature in Telnyx format: t=timestamp,h=base64sig."""
    ts = str(int(time.time()))
    message = ts.encode() + b"." + payload
    sig = hmac.new(secret.encode(), message, hashlib.sha256).digest()
    return f"t={ts},h={base64.b64encode(sig).decode()}"


def _make_ed25519_signature_and_key(payload: bytes):
    """Create valid Ed25519 signature. Returns (public_key_pem, timestamp, signature_b64)."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization

    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key()
    ts = str(int(time.time()))
    # Telnyx legacy Ed25519 scheme signs "timestamp|body" (pipe delimiter).
    signed_payload = ts.encode() + b"|" + payload
    signature = private_key.sign(signed_payload)
    sig_b64 = base64.b64encode(signature).decode()

    pem = public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()
    return pem, ts, sig_b64


@pytest.fixture
def client():
    """Test client with mocked handle_voice_webhook."""
    with patch("main.handle_voice_webhook", new_callable=AsyncMock) as mock_handler:
        mock_handler.return_value = {"success": True}
        with TestClient(app) as c:
            yield c


@pytest.fixture
def mock_settings(monkeypatch):
    """Patch settings for verification tests. Returns a helper to set telnyx config."""

    def _set(
        *,
        public_key: str = "",
        webhook_secret: str = "",
        skip_verify: bool = False,
        allowed_ips: str = "",
    ):
        monkeypatch.setattr("config.settings.telnyx_public_key", public_key)
        monkeypatch.setattr("config.settings.telnyx_webhook_secret", webhook_secret)
        monkeypatch.setattr("config.settings.telnyx_skip_verify", skip_verify)
        monkeypatch.setattr("config.settings.telnyx_allowed_ips", allowed_ips)

    return _set


def test_correct_ed25519_signature(client, mock_settings):
    """Valid Ed25519 signature yields 200."""
    payload_bytes = SAMPLE_JSON.encode()
    pubkey, ts, sig_b64 = _make_ed25519_signature_and_key(payload_bytes)
    mock_settings(public_key=pubkey)

    r = client.post(
        "/api/telnyx/voice",
        content=payload_bytes,
        headers={
            "Content-Type": "application/json",
            "telnyx-signature-ed25519": sig_b64,
            "telnyx-timestamp": ts,
        },
    )
    assert r.status_code == 200
    assert r.json() == {"success": True}


def test_missing_headers_skip_verify_enabled(client, mock_settings):
    """Missing Ed25519 headers + TELNYX_SKIP_VERIFY=true yields 403 when allowlist is empty."""
    mock_settings(skip_verify=True, allowed_ips="")

    r = client.post(
        "/api/telnyx/voice",
        content=SAMPLE_JSON,
        headers={"Content-Type": "application/json"},
    )
    assert r.status_code == 403
    assert "verification failed" in r.json().get("detail", "").lower()


def test_missing_headers_skip_verify_disabled(client, mock_settings):
    """Missing headers + TELNYX_SKIP_VERIFY=false yields 403 when no HMAC configured."""
    mock_settings(skip_verify=False, webhook_secret="")

    r = client.post(
        "/api/telnyx/voice",
        content=SAMPLE_JSON,
        headers={"Content-Type": "application/json"},
    )
    assert r.status_code == 403
    assert "verification failed" in r.json().get("detail", "").lower()


def test_wrong_signature_ed25519(client, mock_settings):
    """Wrong Ed25519 signature yields 403."""
    payload_bytes = SAMPLE_JSON.encode()
    pubkey, ts, _ = _make_ed25519_signature_and_key(payload_bytes)
    mock_settings(public_key=pubkey)

    r = client.post(
        "/api/telnyx/voice",
        content=payload_bytes,
        headers={
            "Content-Type": "application/json",
            "telnyx-signature-ed25519": "invalid_base64_signature",
            "telnyx-timestamp": ts,
        },
    )
    assert r.status_code == 403


def test_hmac_mode_valid_signature(client, mock_settings):
    """Valid HMAC signature with TELNYX_WEBHOOK_SECRET yields 200."""
    secret = "whsec_test123"
    payload_bytes = SAMPLE_JSON.encode()
    sig = _make_hmac_signature(payload_bytes, secret)
    mock_settings(webhook_secret=secret)

    r = client.post(
        "/api/telnyx/voice",
        content=payload_bytes,
        headers={
            "Content-Type": "application/json",
            "x-telnyx-signature": sig,
        },
    )
    assert r.status_code == 200
    assert r.json() == {"success": True}


def test_hmac_mode_wrong_signature(client, mock_settings):
    """Wrong HMAC signature yields 403."""
    mock_settings(webhook_secret="whsec_test123")

    r = client.post(
        "/api/telnyx/voice",
        content=SAMPLE_JSON,
        headers={
            "Content-Type": "application/json",
            "x-telnyx-signature": "t=1234567890,h=invalid",
        },
    )
    assert r.status_code == 403


def test_ip_allowlist_skip_verify_rejects_unknown_ip(client, mock_settings):
    """When TELNYX_SKIP_VERIFY=true and TELNYX_ALLOWED_IPS set, unknown IP gets 403."""
    mock_settings(skip_verify=True, allowed_ips="192.168.1.1,10.0.0.1")

    # Client typically connects as 127.0.0.1; not in allowlist
    r = client.post(
        "/api/telnyx/voice",
        content=SAMPLE_JSON,
        headers={"Content-Type": "application/json"},
    )
    # 127.0.0.1 is not in allowlist
    assert r.status_code == 403


def test_ip_allowlist_skip_verify_allows_allowlisted_ip(client, mock_settings):
    """When TELNYX_SKIP_VERIFY=true and client IP is allowlisted, request yields 200."""
    mock_settings(skip_verify=True, allowed_ips="127.0.0.1")

    r = client.post(
        "/api/telnyx/voice",
        content=SAMPLE_JSON,
        headers={"Content-Type": "application/json", "x-forwarded-for": "127.0.0.1"},
    )
    assert r.status_code == 200
    assert r.json() == {"success": True}


def test_invalid_json_returns_400(client, mock_settings):
    """Invalid JSON body returns 400 (after verification passes)."""
    mock_settings(skip_verify=True, allowed_ips="1.2.3.4")

    r = client.post(
        "/api/telnyx/voice",
        content=b"not valid json",
        headers={"Content-Type": "application/json", "x-forwarded-for": "1.2.3.4"},
    )
    assert r.status_code == 400
