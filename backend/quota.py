"""
Quota check for outbound and inbound calls.
Before initiating outbound, check remaining outbound minutes; block if 0.
Before answering inbound, check remaining inbound minutes; reject if 0.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from billing.subscriptions import is_apple_billed

if TYPE_CHECKING:
    from supabase import Client

_PLAN_COLUMNS = (
    "billing_plan, allocated_inbound_minutes, allocated_outbound_minutes, "
    "used_inbound_minutes, used_outbound_minutes"
)

_APPLE_CAP_REASON = "Included minutes used. Upgrade your plan to continue."


def _apple_hard_cap(plan: dict) -> dict:
    """Apple-billed accounts stop at the included minutes. No overage."""
    allocated = float(plan.get("allocated_inbound_minutes") or 0) + float(
        plan.get("allocated_outbound_minutes") or 0
    )
    used = float(plan.get("used_inbound_minutes") or 0) + float(
        plan.get("used_outbound_minutes") or 0
    )
    remaining = max(0.0, allocated - used)
    if remaining <= 0:
        return {"allowed": False, "remainingMinutes": 0, "reason": _APPLE_CAP_REASON}
    return {"allowed": True, "remainingMinutes": remaining, "reason": None}


def check_inbound_quota(supabase: "Client", user_id: str) -> dict:
    """
    Check if user has remaining inbound minutes.
    For PAYG users: always allowed (no quota).
    For fixed plans: check allocated_inbound_minutes - used_inbound_minutes.
    Returns {"allowed": bool, "remainingMinutes": float | None, "reason": str | None}
    """
    res = supabase.table("user_plans").select(_PLAN_COLUMNS).eq("user_id", user_id).limit(1).execute()

    plan = None
    if res.data and len(res.data) > 0:
        plan = res.data[0]

    if not plan:
        return {"allowed": True, "remainingMinutes": float("inf"), "reason": None}

    if plan.get("billing_plan") == "subscription_payg":
        return {"allowed": True, "remainingMinutes": float("inf"), "reason": None}

    if is_apple_billed(supabase, user_id):
        return _apple_hard_cap(plan)

    allocated = plan.get("allocated_inbound_minutes") or 0
    used = float(plan.get("used_inbound_minutes") or 0)
    remaining = max(0, allocated - used)

    if remaining <= 0:
        return {
            "allowed": False,
            "remainingMinutes": 0,
            "reason": "No inbound minutes remaining this period",
        }

    return {"allowed": True, "remainingMinutes": remaining, "reason": None}


def check_outbound_quota(supabase: "Client", user_id: str) -> dict:
    """
    Check if user has remaining outbound minutes.
    For PAYG users: always allowed (no quota).
    For fixed plans: check allocated_outbound_minutes - used_outbound_minutes.
    Returns {"allowed": bool, "remainingMinutes": float | None, "reason": str | None}
    """
    res = supabase.table("user_plans").select(_PLAN_COLUMNS).eq("user_id", user_id).limit(1).execute()

    plan = None
    if res.data and len(res.data) > 0:
        plan = res.data[0]

    if not plan:
        return {"allowed": False, "remainingMinutes": None, "reason": "No plan configured"}

    if plan.get("billing_plan") == "subscription_payg":
        return {"allowed": True, "remainingMinutes": float("inf"), "reason": None}

    if is_apple_billed(supabase, user_id):
        return _apple_hard_cap(plan)

    allocated = plan.get("allocated_outbound_minutes") or 0
    used = float(plan.get("used_outbound_minutes") or 0)
    remaining = max(0, allocated - used)

    if remaining <= 0:
        return {
            "allowed": False,
            "remainingMinutes": 0,
            "reason": "No outbound minutes remaining this period",
        }

    return {"allowed": True, "remainingMinutes": remaining, "reason": None}
