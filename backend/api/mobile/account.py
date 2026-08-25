"""Delete the signed-in EchoDesk account (App Store / Play requirement)."""

from __future__ import annotations

import logging
from typing import Any

import stripe
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from api.auth import get_user_from_request
from config import settings
from telnyx import provision as telnyx_provision
from telnyx.phone_lifecycle import (
    collect_account_phone_inventory,
    mark_held_number_released,
)

logger = logging.getLogger(__name__)
router = APIRouter()


def _cancel_stripe_for_user(user_row: dict[str, Any]) -> None:
    sk = (settings.stripe_secret_key or "").strip()
    customer_id = (user_row.get("stripe_customer_id") or "").strip()
    if not sk or not customer_id:
        return
    stripe.api_key = sk
    try:
        subs = stripe.Subscription.list(customer=customer_id, status="all", limit=20)
        for sub in getattr(subs, "data", None) or []:
            status = getattr(sub, "status", None) or ""
            if status in {"active", "trialing", "past_due", "unpaid", "incomplete"}:
                stripe.Subscription.delete(sub.id)
    except Exception as err:
        logger.warning("[account/delete] stripe subscription cancel failed: %s", err)
    try:
        stripe.Customer.delete(customer_id)
    except Exception as err:
        logger.warning("[account/delete] stripe customer delete failed: %s", err)


def _release_account_numbers(supabase: Any, user_id: str) -> list[str]:
    released: list[str] = []
    try:
        inventory = collect_account_phone_inventory(supabase, user_id)
    except Exception as err:
        logger.warning("[account/delete] inventory failed user=%s: %s", user_id, err)
        return released
    for item in inventory or []:
        e164 = str(item.get("e164") or "")
        tid = str(item.get("telnyx_id") or "").strip() or None
        if not e164 and not tid:
            continue
        try:
            if tid:
                telnyx_provision.release_number(tid)
        except Exception as err:
            logger.warning(
                "[account/delete] Telnyx release failed phone=%s id=%s: %s",
                e164,
                tid,
                err,
            )
        try:
            mark_held_number_released(
                supabase,
                phone_number=e164,
                telnyx_phone_number_id=tid,
            )
        except Exception as err:
            logger.warning("[account/delete] clear DID from DB failed phone=%s: %s", e164, err)
        if e164:
            released.append(e164)
    return released


def delete_account_for_user(supabase: Any, user_id: str) -> dict[str, Any]:
    """Release numbers, cancel billing, delete profile + auth user."""
    uid = (user_id or "").strip()
    if not uid:
        raise ValueError("missing user_id")

    profile: dict[str, Any] = {}
    try:
        row = (
            supabase.table("users")
            .select("id, email, stripe_customer_id")
            .eq("id", uid)
            .limit(1)
            .execute()
        )
        if row.data:
            profile = row.data[0] or {}
    except Exception as err:
        logger.warning("[account/delete] load profile failed user=%s: %s", uid, err)

    released = _release_account_numbers(supabase, uid)
    _cancel_stripe_for_user(profile)

    try:
        supabase.table("users").update({"active_business_id": None}).eq("id", uid).execute()
    except Exception as err:
        logger.debug("[account/delete] clear active_business_id: %s", err)

    supabase.table("users").delete().eq("id", uid).execute()
    supabase.auth.admin.delete_user(uid)
    logger.warning("[account/delete] deleted user=%s phones=%s", uid, ",".join(released) or "-")
    return {"deleted": True, "released_numbers": released}


@router.delete("/account")
async def delete_account(request: Request):
    user, supabase = get_user_from_request(request)
    if not user or not supabase:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    try:
        result = delete_account_for_user(supabase, user["id"])
    except Exception as err:
        logger.exception("[account/delete] failed user=%s: %s", user.get("id"), err)
        return JSONResponse(
            {"error": "Couldn't delete your account. Please try again or email support."},
            status_code=500,
        )
    return {"ok": True, **result}
