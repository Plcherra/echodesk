"""Subscription lookup and Stripe sync helpers."""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger(__name__)

VALID_SUBSCRIPTION_STATUSES = {"active", "trialing", "grace_period"}
BLOCKED_SUBSCRIPTION_STATUSES = {
    "inactive",
    "past_due",
    "canceled",
    "incomplete",
    "incomplete_expired",
    "unpaid",
}


def _normalize_status(status: Any) -> str:
    return str(status or "").strip().lower()


def get_active_subscription(supabase: Any, user_id: str) -> dict[str, Any] | None:
    """Return newest valid subscription for user."""
    try:
        r = (
            supabase.table("subscriptions")
            .select("*")
            .eq("user_id", user_id)
            .in_("status", sorted(VALID_SUBSCRIPTION_STATUSES))
            .execute()
        )
        rows = [x for x in (r.data or []) if isinstance(x, dict)]
        rows.sort(key=lambda x: str(x.get("created_at") or ""), reverse=True)
        if rows:
            return rows[0]
    except Exception as e:
        logger.warning("[subscriptions] lookup failed user=%s: %s", user_id, e)
    return None


def _sort_newest(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        rows,
        key=lambda row: str(row.get("updated_at") or row.get("created_at") or ""),
        reverse=True,
    )


def _source_key(row: dict[str, Any]) -> str:
    return str(row.get("billing_source") or "").strip().lower()


def _parse_timestamp(value: Any) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    text = str(value).strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def entitlement_period_open(row: dict[str, Any], now: datetime | None = None) -> bool:
    """False when a time-limited row is past its period.

    Rows with no end date stay open (manual comps and older Stripe rows).
    Billing grace stays open because Apple extends access past expires_at.
    """
    if _normalize_status(row.get("status")) == "grace_period":
        return True
    if _normalize_status(row.get("status")) not in VALID_SUBSCRIPTION_STATUSES:
        return False
    end = _parse_timestamp(row.get("expires_at") or row.get("current_period_end"))
    if end is None:
        return True
    current = now or datetime.now(timezone.utc)
    return end > current


def select_access_subscription(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Pick the row that decides access.

    The newest row wins, matching Stripe replacements. When that row is not
    entitled, an entitled row from a different billing source still grants
    access, so an Apple subscription is not hidden by an older Stripe
    cancellation and a comp or Stripe subscription is not hidden by an Apple
    expiration. Two rows with the same source keep the newest-row rule.
    """
    ordered = _sort_newest([row for row in rows if isinstance(row, dict)])
    if not ordered:
        return None
    latest = ordered[0]
    if _normalize_status(latest.get("status")) in VALID_SUBSCRIPTION_STATUSES:
        return latest
    latest_source = _source_key(latest)
    for row in ordered[1:]:
        if _source_key(row) == latest_source:
            continue
        if _normalize_status(row.get("status")) not in VALID_SUBSCRIPTION_STATUSES:
            continue
        # An expired launch trial must not revive access after a later cancellation.
        if not entitlement_period_open(row):
            continue
        return row
    return latest


def is_apple_billed(
    supabase: Any,
    user_id: str,
    metadata: dict[str, Any] | None = None,
) -> bool:
    """True when this account's current entitlement is billed by Apple.

    An active subscription row wins over leftover billing metadata, so a Stripe
    plan that outlives an Apple subscription is not stuck on the Apple cap.
    """
    subscription = get_active_subscription(supabase, user_id)
    if subscription:
        return _source_key(subscription) == "apple"
    return str((metadata or {}).get("billing_source") or "").strip().lower() == "apple"


def should_preserve_user_access(
    supabase: Any,
    user_id: str,
    *,
    except_provider_subscription_id: str | None = None,
    except_apple_original_transaction_id: str | None = None,
) -> bool:
    """True when some other entitled subscription should keep the account active.

    Lookup failures return True so a Stripe cancellation cannot drop an Apple
    subscriber we failed to read.
    """
    try:
        result = (
            supabase.table("subscriptions")
            .select("*")
            .eq("user_id", user_id)
            .in_("status", sorted(VALID_SUBSCRIPTION_STATUSES))
            .execute()
        )
    except Exception as exc:
        logger.warning("[subscriptions] preserve-access lookup failed user=%s: %s", user_id, exc)
        return True
    return _first_other_entitled(
        result.data or [],
        except_provider_subscription_id=except_provider_subscription_id,
        except_apple_original_transaction_id=except_apple_original_transaction_id,
    ) is not None


def other_entitled_subscription(
    supabase: Any,
    user_id: str,
    *,
    except_provider_subscription_id: str | None = None,
    except_apple_original_transaction_id: str | None = None,
) -> dict[str, Any] | None:
    """The other still-valid subscription, or None when the lookup fails."""
    try:
        result = (
            supabase.table("subscriptions")
            .select("*")
            .eq("user_id", user_id)
            .in_("status", sorted(VALID_SUBSCRIPTION_STATUSES))
            .execute()
        )
    except Exception as exc:
        logger.warning("[subscriptions] other-entitled lookup failed user=%s: %s", user_id, exc)
        return None
    return _first_other_entitled(
        result.data or [],
        except_provider_subscription_id=except_provider_subscription_id,
        except_apple_original_transaction_id=except_apple_original_transaction_id,
    )


def _first_other_entitled(
    rows: list[Any],
    *,
    except_provider_subscription_id: str | None,
    except_apple_original_transaction_id: str | None,
) -> dict[str, Any] | None:
    for row in rows:
        if not isinstance(row, dict):
            continue
        provider_id = str(row.get("billing_provider_subscription_id") or "")
        if except_provider_subscription_id and provider_id == str(except_provider_subscription_id):
            continue
        apple_id = str(row.get("apple_original_transaction_id") or "")
        if except_apple_original_transaction_id and apple_id == str(except_apple_original_transaction_id):
            continue
        if not entitlement_period_open(row):
            continue
        return row
    return None


def get_billing_access_state(
    supabase: Any,
    user_id: str,
    *,
    profile: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return the backend's subscription access decision for app gating.

    Stripe's subscription table is authoritative when it has a row. The legacy
    users.subscription_status field is only a fallback for older accounts or
    partially migrated data.
    """
    latest_subscription = None
    try:
        r = (
            supabase.table("subscriptions")
            .select("*")
            .eq("user_id", user_id)
            .execute()
        )
        rows = [x for x in (r.data or []) if isinstance(x, dict)]
        latest_subscription = select_access_subscription(rows)
    except Exception as e:
        logger.warning("[subscriptions] access state lookup failed user=%s: %s", user_id, e)

    if latest_subscription:
        status = _normalize_status(latest_subscription.get("status"))
        return {
            "has_active_subscription": status in VALID_SUBSCRIPTION_STATUSES,
            "status": status or None,
            "source": "subscriptions",
            "subscription": latest_subscription,
        }

    profile_status = _normalize_status((profile or {}).get("subscription_status"))
    return {
        "has_active_subscription": profile_status in VALID_SUBSCRIPTION_STATUSES,
        "status": profile_status or None,
        "source": "users" if profile_status else "none",
        "subscription": None,
    }


def get_plan_id_for_code(supabase: Any, code: str) -> str | None:
    try:
        r = supabase.table("plans").select("id").eq("code", code).eq("is_active", True).limit(1).execute()
        if r.data and len(r.data) > 0:
            return str(r.data[0]["id"])
    except Exception as e:
        logger.warning("[subscriptions] plan lookup failed code=%s: %s", code, e)
    return None
