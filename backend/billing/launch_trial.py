"""Activate the launch free trial for eligible new accounts."""

from __future__ import annotations

import logging
import os
from datetime import datetime, timedelta
from typing import Any

from billing.subscriptions import VALID_SUBSCRIPTION_STATUSES, get_billing_access_state, get_plan_id_for_code
from trial_offer import compute_trial_spots

logger = logging.getLogger(__name__)

DEFAULT_TRIAL_TOTAL_SPOTS = 100
DEFAULT_TRIAL_DAYS = 14
DEFAULT_TRIAL_INCLUDED_MINUTES = 60


def _env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        logger.warning("Invalid %s=%r; using default %s", name, raw, default)
        return default


def _count_users(supabase: Any) -> int:
    cutoff = (os.environ.get("TRIAL_LAUNCH_CUTOFF") or "").strip()
    query = supabase.table("users").select("id", count="exact")
    if cutoff:
        query = query.gte("created_at", cutoff)
    res = query.execute()
    count = getattr(res, "count", None)
    if count is None:
        data = getattr(res, "data", None) or []
        count = len(data)
    return int(count or 0)


def _normalize_status(status: Any) -> str:
    return str(status or "").strip().lower()


def maybe_activate_launch_trial(
    supabase: Any,
    user_id: str,
    profile: dict[str, Any],
    *,
    sync_user_plan,
) -> dict[str, Any]:
    """Grant a 14-day launch trial when spots remain and the account is unpaid.

    Returns the (possibly updated) profile row.
    """
    billing = get_billing_access_state(supabase, user_id, profile=profile)
    if billing.get("has_active_subscription"):
        return profile

    status = _normalize_status(profile.get("subscription_status"))
    # Do not revive canceled/past_due paid accounts into a free trial.
    if status in {"past_due", "canceled", "unpaid", "incomplete", "incomplete_expired"}:
        return profile
    if status in VALID_SUBSCRIPTION_STATUSES:
        return profile

    total = _env_int("TRIAL_TOTAL_SPOTS", DEFAULT_TRIAL_TOTAL_SPOTS)
    baseline = _env_int("TRIAL_USERS_BASELINE", 0)
    try:
        user_count = _count_users(supabase)
    except Exception as e:
        logger.warning("[launch_trial] user count failed: %s", e)
        return profile

    spots = compute_trial_spots(
        total_spots=total,
        user_count=user_count,
        users_baseline=baseline,
    )
    if spots["remaining"] <= 0:
        return profile

    trial_days = _env_int("TRIAL_DAYS", DEFAULT_TRIAL_DAYS)
    included = _env_int("TRIAL_INCLUDED_MINUTES", DEFAULT_TRIAL_INCLUDED_MINUTES)
    now = datetime.utcnow()
    period_end = now + timedelta(days=trial_days)
    now_iso = now.isoformat() + "Z"
    end_iso = period_end.isoformat() + "Z"

    plan_id = get_plan_id_for_code(supabase, "starter")
    plan_payload = {
        "billing_plan": "subscription_starter",
        "billing_plan_metadata": {
            "included_minutes": included,
            "overage_rate_cents": 20,
            "monthly_fee_cents": 0,
            "launch_trial": True,
            "trial_days": trial_days,
        },
    }

    try:
        supabase.table("subscriptions").insert(
            {
                "user_id": user_id,
                "plan_id": plan_id,
                "status": "trialing",
                "current_period_start": now_iso,
                "current_period_end": end_iso,
                "cancel_at_period_end": True,
                "updated_at": now_iso,
            }
        ).execute()
    except Exception as e:
        logger.warning("[launch_trial] subscriptions insert failed user=%s: %s", user_id, e)
        return profile

    try:
        updated = (
            supabase.table("users")
            .update(
                {
                    "subscription_status": "trialing",
                    "billing_plan": plan_payload["billing_plan"],
                    "billing_plan_metadata": plan_payload["billing_plan_metadata"],
                    "updated_at": now_iso,
                }
            )
            .eq("id", user_id)
            .execute()
        )
        if updated.data:
            profile = updated.data[0]
        else:
            profile = {
                **profile,
                "subscription_status": "trialing",
                "billing_plan": plan_payload["billing_plan"],
                "billing_plan_metadata": plan_payload["billing_plan_metadata"],
            }
    except Exception as e:
        logger.warning("[launch_trial] users update failed user=%s: %s", user_id, e)
        return profile

    try:
        sync_user_plan(supabase, user_id, plan_payload)
    except Exception as e:
        logger.warning("[launch_trial] user_plans sync failed user=%s: %s", user_id, e)

    logger.info(
        "[launch_trial] activated user=%s days=%s minutes=%s remaining_before=%s",
        user_id,
        trial_days,
        included,
        spots["remaining"],
    )
    return profile
