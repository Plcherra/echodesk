"""Map a verified Apple transaction and notification onto a subscription status.

This module does not call Apple or the database. Callers pass already-decoded
fields so the rules can be tested with mocked payloads.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from billing.apple_plans import plan_for_product_id

AUTO_RENEWABLE_TYPES = {
    "Auto-Renewable Subscription",
    "AUTO_RENEWABLE_SUBSCRIPTION",
}

_REVOKED_NOTIFICATIONS = {"REFUND", "REVOKE"}


def _upper(value: Any) -> str | None:
    if value is None:
        return None
    text = str(getattr(value, "value", value) or "").strip()
    if not text:
        return None
    return text.upper()


def _as_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    raw = getattr(value, "value", value)
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def _auto_renew_disabled(value: Any, subtype: str | None) -> bool:
    if subtype == "AUTO_RENEW_DISABLED":
        return True
    if subtype == "AUTO_RENEW_ENABLED":
        return False
    if value is None:
        return False
    if isinstance(value, bool):
        return not value
    raw = getattr(value, "value", value)
    text = str(raw).strip().lower()
    if text in {"0", "off", "false"}:
        return True
    if text in {"1", "on", "true"}:
        return False
    return False


def _event_signed_ms(transaction: dict[str, Any], notification_signed_date_ms: int | None) -> int | None:
    values: list[int] = []
    for raw in (transaction.get("signed_date_ms"), notification_signed_date_ms):
        parsed = _as_int(raw)
        if parsed is not None:
            values.append(parsed)
    return max(values) if values else None


def decide_apple_entitlement(
    transaction: dict[str, Any] | None,
    *,
    notification_type: Any = None,
    subtype: Any = None,
    apple_status: Any = None,
    auto_renew_status: Any = None,
    notification_signed_date_ms: int | None = None,
    now_ms: int | None = None,
) -> dict[str, Any]:
    """Return the subscription row this Apple event should produce.

    `apple_status` is Apple's subscription status integer: 1 active, 2 expired,
    3 billing retry, 4 billing grace period, 5 revoked.
    """
    ntype = _upper(notification_type)
    sub = _upper(subtype)
    if ntype == "TEST":
        return {"ignored": True, "reason": "test_notification"}

    tx = transaction or {}
    if not str(tx.get("original_transaction_id") or "").strip():
        return {"ignored": True, "reason": "no_transaction"}

    now = int(now_ms if now_ms is not None else datetime.now(timezone.utc).timestamp() * 1000)
    product_id = str(tx.get("product_id") or "").strip() or None
    plan = plan_for_product_id(product_id)
    tx_type = str(tx.get("type") or "").strip()
    revocation_ms = _as_int(tx.get("revocation_date_ms"))
    expires_ms = _as_int(tx.get("expires_date_ms"))
    status_int = _as_int(apple_status)

    base = {
        "ignored": False,
        "product_id": product_id,
        "plan": plan,
        "original_transaction_id": str(tx.get("original_transaction_id")).strip(),
        "transaction_id": str(tx.get("transaction_id") or "").strip() or None,
        "expires_date_ms": expires_ms,
        "purchase_date_ms": _as_int(tx.get("purchase_date_ms")),
        "signed_date_ms": _event_signed_ms(tx, notification_signed_date_ms),
        "environment": str(tx.get("environment") or "").strip() or None,
        "app_account_token": str(tx.get("app_account_token") or "").strip() or None,
        "cancel_at_period_end": False,
        "billing_grace": False,
    }

    if tx_type and tx_type not in AUTO_RENEWABLE_TYPES:
        return {
            **base,
            "status": "canceled",
            "entitled": False,
            "reason": "unsupported_product_type",
        }

    # A REFUND for an older renewal can arrive while the subscription status
    # is still active. That must not replace the current paid period.
    if ntype == "REFUND" and status_int in {1, 4}:
        return {**base, "ignored": True, "reason": "refunded_prior_transaction"}

    if revocation_ms or ntype in _REVOKED_NOTIFICATIONS or status_int == 5:
        status, entitled, grace, reason = "canceled", False, False, "revoked"
    elif ntype == "GRACE_PERIOD_EXPIRED":
        status, entitled, grace, reason = "canceled", False, False, "grace_period_expired"
    elif ntype == "EXPIRED" or status_int == 2:
        status, entitled, grace, reason = "canceled", False, False, "expired"
    elif (ntype == "DID_FAIL_TO_RENEW" and sub == "GRACE_PERIOD") or status_int == 4:
        status, entitled, grace, reason = "grace_period", True, True, "billing_grace"
    elif ntype == "DID_FAIL_TO_RENEW" or status_int == 3:
        status, entitled, grace, reason = "past_due", False, False, "billing_retry"
    elif expires_ms is not None and expires_ms <= now:
        status, entitled, grace, reason = "canceled", False, False, "expired"
    elif plan is None:
        status, entitled, grace, reason = "past_due", False, False, "unknown_product"
    else:
        status, entitled, grace, reason = "active", True, False, "active"

    if entitled and not grace and expires_ms is not None and expires_ms <= now:
        status, entitled, reason = "canceled", False, "expired"
    if entitled and plan is None:
        status, entitled, grace, reason = "past_due", False, False, "unknown_product"

    return {
        **base,
        "status": status,
        "entitled": entitled,
        "billing_grace": grace,
        "cancel_at_period_end": _auto_renew_disabled(auto_renew_status, sub) if entitled else False,
        "reason": reason,
    }
