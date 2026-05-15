"""Sync Stripe Subscription objects into public.subscriptions."""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger(__name__)


def _stripe_ts_to_iso(ts: int | None) -> str | None:
    if ts is None:
        return None
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).isoformat()


def _plan_code_from_plan_dict(plan: dict[str, Any]) -> str | None:
    code = plan.get("plan_code")
    if code:
        return str(code)
    bp = plan.get("billing_plan") or ""
    if isinstance(bp, str) and bp.startswith("subscription_"):
        return bp.replace("subscription_", "")
    return None


def stripe_subscription_status_to_db_status(status: Any) -> str:
    raw = str(status or "").strip().lower()
    st_map = {
        "trialing": "trialing",
        "active": "active",
        "past_due": "past_due",
        "canceled": "canceled",
        "incomplete": "past_due",
        "incomplete_expired": "canceled",
        "unpaid": "past_due",
    }
    return st_map.get(raw, "past_due")


def upsert_subscription_from_stripe(
    supabase: Any,
    *,
    user_id: str,
    stripe_subscription: Any,
    plan: dict[str, Any],
) -> None:
    """Upsert subscriptions row for Option A anniversary periods."""
    from billing.subscriptions import get_plan_id_for_code

    code = _plan_code_from_plan_dict(plan)
    plan_id = get_plan_id_for_code(supabase, code) if code else None

    db_status = stripe_subscription_status_to_db_status(getattr(stripe_subscription, "status", None))

    cust = stripe_subscription.customer
    customer_id = cust if isinstance(cust, str) else getattr(cust, "id", None)

    row = {
        "user_id": user_id,
        "plan_id": plan_id,
        "status": db_status,
        "billing_provider_customer_id": customer_id,
        "billing_provider_subscription_id": stripe_subscription.id,
        "current_period_start": _stripe_ts_to_iso(getattr(stripe_subscription, "current_period_start", None)),
        "current_period_end": _stripe_ts_to_iso(getattr(stripe_subscription, "current_period_end", None)),
        "cancel_at_period_end": bool(getattr(stripe_subscription, "cancel_at_period_end", False)),
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }

    try:
        existing = (
            supabase.table("subscriptions")
            .select("id")
            .eq("billing_provider_subscription_id", stripe_subscription.id)
            .limit(1)
            .execute()
        )
        if existing.data and len(existing.data) > 0:
            supabase.table("subscriptions").update(row).eq(
                "billing_provider_subscription_id", stripe_subscription.id
            ).execute()
        else:
            row["created_at"] = datetime.now(timezone.utc).isoformat()
            supabase.table("subscriptions").insert(row).execute()
    except Exception as e:
        logger.exception("[stripe_sync] upsert subscription failed: %s", e)


def mark_subscription_canceled(supabase: Any, *, stripe_subscription_id: str) -> None:
    try:
        supabase.table("subscriptions").update(
            {
                "status": "canceled",
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }
        ).eq("billing_provider_subscription_id", stripe_subscription_id).execute()
    except Exception as e:
        logger.warning("[stripe_sync] mark canceled failed: %s", e)
