"""Telnyx webhook signature validation."""

from __future__ import annotations

import base64
import hmac
import hashlib
import time
from typing import Any


def verify_hmac(
    payload: bytes,
    signature: str,
    webhook_secret: str,
) -> bool:
    """
    Validate Telnyx webhook signature via HMAC-SHA256.
    Header format: t=timestamp,h=base64signature
    Message: timestamp + '.' + raw_body
    """
    if not webhook_secret or not signature or not signature.strip():
        return False

    secret = webhook_secret.encode("utf-8")

    try:
        parts = signature.strip().split(",")
        t_val = h_val = None
        for p in parts:
            p = p.strip()
            if p.startswith("t="):
                t_val = p[2:]
            elif p.startswith("h="):
                h_val = p[2:]

        if not t_val or not h_val:
            return False

        # Timestamp check (±60s)
        ts = int(t_val)
        if abs(time.time() - ts) > 60:
            return False

        message = t_val.encode() + b"." + payload
        expected = hmac.new(secret, message, hashlib.sha256).digest()
        sig_bytes = base64.b64decode(h_val)

        return hmac.compare_digest(sig_bytes, expected)
    except Exception:
        return False


def verify_ed25519(
    payload: bytes,
    timestamp: str,
    signature_b64: str,
    public_key_pem: str,
) -> bool:
    """
    Validate Telnyx webhook signature via Ed25519.
    Headers: telnyx-timestamp, telnyx-signature-ed25519
    Signed payload: timestamp + '|' + body  (Telnyx legacy Ed25519 scheme)
    """
    if not public_key_pem or not timestamp or not signature_b64:
        return False

    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

        # Accept PEM or raw base64 public key
        public_key_bytes = public_key_pem.encode("utf-8") if isinstance(public_key_pem, str) else public_key_pem
        if public_key_bytes.startswith(b"-----"):
            public_key = serialization.load_pem_public_key(public_key_bytes)
        else:
            raw = base64.b64decode(public_key_pem)
            public_key = Ed25519PublicKey.from_public_bytes(raw)

        if not isinstance(public_key, Ed25519PublicKey):
            return False

        # Timestamp check (±60s)
        ts = int(timestamp)
        if abs(time.time() - ts) > 60:
            return False

        signed_payload = timestamp.encode("utf-8") + b"|" + payload
        signature = base64.b64decode(signature_b64)

        public_key.verify(signature, signed_payload)
        return True
    except (InvalidSignature, ValueError, Exception):
        return False


def validate_telnyx_webhook(
    payload: bytes | str,
    signature: str | None,
    *,
    webhook_secret: str | None = None,
    public_key: str | None = None,
    timestamp_header: str | None = None,
    ed25519_signature_header: str | None = None,
) -> bool:
    """
    Validate Telnyx webhook signature.
    Supports:
    - Ed25519: when public_key and ed25519_signature_header are set
    - HMAC-SHA256: when webhook_secret and signature (t=...,h=...) are set
    """
    body = payload if isinstance(payload, bytes) else payload.encode("utf-8")

    # Try Ed25519 first if we have the public key and the Ed25519 header
    if public_key and ed25519_signature_header and timestamp_header:
        if verify_ed25519(
            body,
            timestamp_header,
            ed25519_signature_header,
            public_key,
        ):
            return True
        # Ed25519 failed; don't fall through to HMAC with wrong format
        return False

    # Fall back to HMAC
    if webhook_secret and signature:
        return verify_hmac(body, signature, webhook_secret)

    return False


def should_skip_verification(
    ed25519_headers_present: bool,
    skip_verify_enabled: bool,
) -> tuple[bool, str]:
    """
    Determine if webhook verification should be skipped.

    Skip is only allowed when:
    - Ed25519 headers are missing (stripped by proxy)
    - AND TELNYX_SKIP_VERIFY=true

    Returns:
        (skip: bool, reason: str)
    """
    if not ed25519_headers_present and skip_verify_enabled:
        return (True, "skip_verification")
    return (False, "verification_required")
