"""Subscription lookup and Stripe sync helpers."""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

VALID_SUBSCRIPTION_STATUSES = {"active", "trialing"}
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
        rows.sort(
            key=lambda x: str(x.get("updated_at") or x.get("created_at") or ""),
            reverse=True,
        )
        latest_subscription = rows[0] if rows else None
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
