"""Write a verified Apple subscription onto the EchoDesk account."""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

from billing.apple_entitlement import decide_apple_entitlement
from billing.subscriptions import (
    get_plan_id_for_code,
    other_entitled_subscription,
    should_preserve_user_access,
)

logger = logging.getLogger(__name__)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ms_to_iso(ms: int | None) -> str | None:
    if ms is None:
        return None
    return datetime.fromtimestamp(int(ms) / 1000, tz=timezone.utc).isoformat()


def _norm_uuid(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip().strip("{}").lower()
    return text or None


def _rows(result: Any) -> list[dict[str, Any]]:
    data = getattr(result, "data", None) or []
    return [row for row in data if isinstance(row, dict)]


def _find_by_original_transaction(supabase: Any, original_transaction_id: str) -> dict[str, Any] | None:
    result = (
        supabase.table("subscriptions")
        .select("*")
        .eq("apple_original_transaction_id", original_transaction_id)
        .limit(1)
        .execute()
    )
    rows = _rows(result)
    return rows[0] if rows else None


def _user_exists(supabase: Any, user_id: str) -> str | None:
    result = supabase.table("users").select("id").eq("id", user_id).limit(1).execute()
    rows = _rows(result)
    if not rows:
        return None
    return str(rows[0].get("id") or user_id)


def _is_stale(existing: dict[str, Any] | None, signed_ms: int | None) -> bool:
    if not existing or signed_ms is None:
        return False
    stored = existing.get("apple_signed_date_ms")
    if stored is None:
        return False
    try:
        return int(signed_ms) < int(stored)
    except (TypeError, ValueError):
        return False


APPLE_TRIAL_INCLUDED_MINUTES = 50


def _included_minutes(decision: dict[str, Any]) -> int:
    if decision.get("introductory_trial"):
        return APPLE_TRIAL_INCLUDED_MINUTES
    plan = decision.get("plan") or {}
    return int(plan.get("included_minutes") or 0)


def _metadata(decision: dict[str, Any]) -> dict[str, Any]:
    included = _included_minutes(decision)
    return {
        "included_minutes": included,
        "overage_rate_cents": 0,
        "billing_source": "apple",
        "overage_allowed": False,
        "apple_product_id": decision.get("product_id"),
        "introductory_trial": bool(decision.get("introductory_trial")),
    }


def _sync_entitled_plan(supabase: Any, user_id: str, decision: dict[str, Any], now_iso: str) -> None:
    plan = decision["plan"]
    included = _included_minutes(decision)
    inbound_pct = 80
    outbound_pct = 20
    existing = (
        supabase.table("user_plans")
        .select("inbound_percent, outbound_percent")
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    rows = _rows(existing)
    if rows:
        inbound_pct = int(rows[0].get("inbound_percent") or inbound_pct)
        outbound_pct = int(rows[0].get("outbound_percent") or outbound_pct)
    alloc_in = int((included * inbound_pct) / 100)
    alloc_out = included - alloc_in
    supabase.table("user_plans").upsert(
        {
            "user_id": user_id,
            "billing_plan": plan["billing_plan"],
            "allocated_inbound_minutes": alloc_in,
            "allocated_outbound_minutes": alloc_out,
            "inbound_percent": inbound_pct,
            "outbound_percent": outbound_pct,
            "overage_rate_cents": 0,
            "payg_rate_cents": 0,
            "updated_at": now_iso,
        },
        on_conflict="user_id",
    ).execute()
    supabase.table("users").update(
        {
            "subscription_status": decision["status"],
            "billing_plan": plan["billing_plan"],
            "billing_plan_metadata": _metadata(decision),
            "updated_at": now_iso,
        }
    ).eq("id", user_id).execute()


def _plan_code_for_id(supabase: Any, plan_id: Any) -> str | None:
    if not plan_id:
        return None
    found = supabase.table("plans").select("code").eq("id", plan_id).limit(1).execute()
    rows = _rows(found)
    if rows and rows[0].get("code"):
        return str(rows[0]["code"])
    return None


def _restore_preserved_access(
    supabase: Any,
    user_id: str,
    other: dict[str, Any],
    now_iso: str,
) -> None:
    """Put the still-paid subscription back on the account after Apple access ends."""
    from stripe_plans import PLAN_DEFS

    status = str(other.get("status") or "active")
    source = str(other.get("billing_source") or "").strip().lower()
    code = _plan_code_for_id(supabase, other.get("plan_id"))
    catalog = next((plan for plan in PLAN_DEFS if plan["id"] == code), None) if code else None
    updates: dict[str, Any] = {"subscription_status": status, "updated_at": now_iso}
    if catalog and source != "apple":
        included = int(catalog["included_minutes"])
        overage = int(catalog["overage_rate_cents"])
        updates["billing_plan"] = catalog["billing_plan_id"]
        updates["billing_plan_metadata"] = {
            "included_minutes": included,
            "monthly_fee_cents": catalog["monthly_fee_cents"],
            "overage_rate_cents": overage,
            "billing_source": "stripe",
            "overage_allowed": True,
        }
        inbound_pct = 80
        outbound_pct = 20
        existing = (
            supabase.table("user_plans")
            .select("inbound_percent, outbound_percent")
            .eq("user_id", user_id)
            .limit(1)
            .execute()
        )
        rows = _rows(existing)
        if rows:
            inbound_pct = int(rows[0].get("inbound_percent") or inbound_pct)
            outbound_pct = int(rows[0].get("outbound_percent") or outbound_pct)
        alloc_in = int((included * inbound_pct) / 100)
        supabase.table("user_plans").upsert(
            {
                "user_id": user_id,
                "billing_plan": catalog["billing_plan_id"],
                "allocated_inbound_minutes": alloc_in,
                "allocated_outbound_minutes": included - alloc_in,
                "inbound_percent": inbound_pct,
                "outbound_percent": outbound_pct,
                "overage_rate_cents": overage,
                "payg_rate_cents": 20,
                "updated_at": now_iso,
            },
            on_conflict="user_id",
        ).execute()
    else:
        current = (
            supabase.table("users")
            .select("billing_plan_metadata")
            .eq("id", user_id)
            .limit(1)
            .execute()
        )
        rows = _rows(current)
        meta = dict((rows[0].get("billing_plan_metadata") if rows else None) or {})
        if str(meta.get("billing_source") or "").lower() == "apple":
            if source:
                meta["billing_source"] = source
                meta["overage_allowed"] = source != "apple"
            else:
                meta.pop("billing_source", None)
                meta["overage_allowed"] = True
            updates["billing_plan_metadata"] = meta
    supabase.table("users").update(updates).eq("id", user_id).execute()


def _revoke_access(supabase: Any, user_id: str, decision: dict[str, Any], now_iso: str) -> None:
    plan = decision.get("plan") or {}
    billing_plan = plan.get("billing_plan") or "subscription_starter"
    supabase.table("users").update(
        {
            "subscription_status": decision["status"],
            "billing_plan": billing_plan if plan else None,
            "billing_plan_metadata": _metadata(decision),
            "updated_at": now_iso,
        }
    ).eq("id", user_id).execute()
    existing = (
        supabase.table("user_plans")
        .select("user_id")
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    allocation = {
        "billing_plan": billing_plan,
        "allocated_inbound_minutes": 0,
        "allocated_outbound_minutes": 0,
        "overage_rate_cents": 0,
        "updated_at": now_iso,
    }
    if _rows(existing):
        supabase.table("user_plans").update(allocation).eq("user_id", user_id).execute()
    else:
        supabase.table("user_plans").insert(
            {
                "user_id": user_id,
                "inbound_percent": 80,
                "outbound_percent": 20,
                "payg_rate_cents": 0,
                **allocation,
            }
        ).execute()


def _save_subscription_row(
    supabase: Any,
    *,
    existing: dict[str, Any] | None,
    user_id: str,
    decision: dict[str, Any],
    notification_type: str | None,
    notification_uuid: str | None,
    now_iso: str,
) -> None:
    plan = decision.get("plan") or {}
    code = plan.get("plan_id")
    plan_id = None
    if code:
        try:
            plan_id = get_plan_id_for_code(supabase, str(code))
        except Exception as exc:
            logger.warning("[apple] plan lookup failed code=%s: %s", code, exc)
        if plan_id is None:
            try:
                found = (
                    supabase.table("plans")
                    .select("id")
                    .eq("code", str(code))
                    .limit(1)
                    .execute()
                )
                rows = _rows(found)
                if rows and rows[0].get("id"):
                    plan_id = str(rows[0]["id"])
            except Exception as exc:
                logger.warning("[apple] inactive plan lookup failed code=%s: %s", code, exc)

    row = {
        "user_id": user_id,
        "plan_id": plan_id,
        "status": decision["status"],
        "billing_source": "apple",
        "apple_original_transaction_id": decision["original_transaction_id"],
        "apple_transaction_id": decision.get("transaction_id"),
        "apple_product_id": decision.get("product_id"),
        "apple_environment": decision.get("environment"),
        "apple_app_account_token": _norm_uuid(decision.get("app_account_token")),
        "expires_at": _ms_to_iso(decision.get("expires_date_ms")),
        "current_period_start": _ms_to_iso(decision.get("purchase_date_ms")),
        "current_period_end": _ms_to_iso(decision.get("expires_date_ms")),
        "cancel_at_period_end": bool(decision.get("cancel_at_period_end")),
        "apple_billing_grace": bool(decision.get("billing_grace")),
        "apple_last_notification_type": notification_type,
        "apple_last_notification_uuid": notification_uuid,
        "apple_signed_date_ms": decision.get("signed_date_ms"),
        "updated_at": now_iso,
    }
    if existing and existing.get("id"):
        supabase.table("subscriptions").update(row).eq("id", existing["id"]).execute()
        return
    row["created_at"] = now_iso
    supabase.table("subscriptions").insert(row).execute()


def apply_apple_subscription(
    supabase: Any,
    transaction: dict[str, Any] | None,
    *,
    user_id: str | None = None,
    notification_type: Any = None,
    subtype: Any = None,
    apple_status: Any = None,
    auto_renew_status: Any = None,
    notification_uuid: str | None = None,
    notification_signed_date_ms: int | None = None,
    require_account_token: bool = False,
    now_ms: int | None = None,
) -> dict[str, Any]:
    """Upsert the Apple subscription and, when it is the account's access, the user plan.

    Client verification passes `user_id` and `require_account_token=True`.
    Notifications omit `user_id` and attach the transaction to the account
    already stored for that original transaction, or to `appAccountToken`.
    """
    decision = decide_apple_entitlement(
        transaction,
        notification_type=notification_type,
        subtype=subtype,
        apple_status=apple_status,
        auto_renew_status=auto_renew_status,
        notification_signed_date_ms=notification_signed_date_ms,
        now_ms=now_ms,
    )
    if decision.get("ignored"):
        return {"ok": True, "ignored": True, "reason": decision.get("reason")}

    original_id = str(decision["original_transaction_id"])
    existing = _find_by_original_transaction(supabase, original_id)
    if _is_stale(existing, decision.get("signed_date_ms")):
        return {"ok": True, "ignored": True, "reason": "stale_notification"}

    token = _norm_uuid(decision.get("app_account_token"))
    auth_user = _norm_uuid(user_id)
    if require_account_token:
        if not auth_user:
            return {"ok": False, "status_code": 401, "error": "Sign in required."}
        if not token:
            return {
                "ok": False,
                "status_code": 400,
                "error": "This purchase is not linked to an EchoDesk account.",
            }
        if token != auth_user:
            return {
                "ok": False,
                "status_code": 403,
                "error": "This purchase belongs to a different EchoDesk account.",
            }
        owner = user_id
    elif existing:
        owner = str(existing.get("user_id"))
        if token and token != _norm_uuid(owner):
            return {
                "ok": False,
                "status_code": 409,
                "error": "appAccountToken does not match the subscription owner.",
            }
    else:
        if not token:
            return {"ok": True, "ignored": True, "reason": "no_account_token"}
        owner = _user_exists(supabase, token)
        if not owner:
            return {"ok": True, "ignored": True, "reason": "unknown_account"}

    if existing and _norm_uuid(existing.get("user_id")) != _norm_uuid(owner):
        return {
            "ok": False,
            "status_code": 409,
            "error": "This subscription is already linked to another EchoDesk account.",
        }

    preserve = False
    if not decision.get("entitled"):
        preserve = should_preserve_user_access(
            supabase,
            str(owner),
            except_apple_original_transaction_id=original_id,
        )

    now_iso = _now_iso()
    ntype = str(notification_type).strip().upper() if notification_type else None
    try:
        _save_subscription_row(
            supabase,
            existing=existing,
            user_id=str(owner),
            decision=decision,
            notification_type=ntype,
            notification_uuid=notification_uuid,
            now_iso=now_iso,
        )
    except Exception as exc:
        message = str(exc).lower()
        if "apple_original_transaction_id" in message or "duplicate" in message or "unique" in message:
            return {
                "ok": False,
                "status_code": 409,
                "error": "This subscription is already linked to another EchoDesk account.",
            }
        logger.exception("[apple] subscription upsert failed")
        return {"ok": False, "status_code": 500, "error": "Could not save the subscription."}

    if decision.get("entitled"):
        _sync_entitled_plan(supabase, str(owner), decision, now_iso)
    elif preserve:
        other = other_entitled_subscription(
            supabase,
            str(owner),
            except_apple_original_transaction_id=original_id,
        )
        if other:
            _restore_preserved_access(supabase, str(owner), other, now_iso)
    else:
        _revoke_access(supabase, str(owner), decision, now_iso)

    return {
        "ok": True,
        "ignored": False,
        "status": decision["status"],
        "entitled": bool(decision.get("entitled")),
        "reason": decision.get("reason"),
        "user_id": str(owner),
        "product_id": decision.get("product_id"),
        "preserved_other_billing": preserve,
    }
