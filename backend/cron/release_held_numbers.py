"""Auto-release held DIDs after HOLD_HOURS if the customer did not reclaim them."""

from __future__ import annotations

import logging
from typing import Any

from telnyx.phone_lifecycle import (
    HOLD_HOURS,
    collect_account_phone_inventory,
    expired_held_numbers,
    mark_held_number_released,
)
from utils.internal_notify import notify_customer_number_released

logger = logging.getLogger(__name__)


def release_expired_held_numbers(supabase: Any, *, hold_hours: int = HOLD_HOURS) -> dict[str, Any]:
    """
    For each unused held DID older than hold_hours: detach from the customer,
    keep the DID on our Telnyx account for the next receptionist, email customer.

    Skip if the number is live again (they kept/reattached it).
    Do not delete the number in Telnyx — acquire_phone_number reuses orphans.
    """
    released: list[str] = []
    skipped: list[str] = []
    errors: list[str] = []

    try:
        users = supabase.table("businesses").select("owner_user_id").execute()
    except Exception as e:
        logger.warning("[cron/release-held] list owners failed: %s", e)
        return {"released": [], "skipped": [], "errors": [str(e)]}

    owner_ids = sorted(
        {
            str(r.get("owner_user_id") or "").strip()
            for r in (users.data or [])
            if str(r.get("owner_user_id") or "").strip()
        }
    )

    for uid in owner_ids:
        try:
            inventory = collect_account_phone_inventory(supabase, uid)
        except Exception as e:
            errors.append(f"{uid}: inventory {e}")
            continue
        for item in expired_held_numbers(inventory, hold_hours=hold_hours):
            e164 = str(item.get("e164") or "")
            tid = str(item.get("telnyx_id") or "").strip() or None
            if not e164 and not tid:
                continue
            if item.get("live"):
                skipped.append(e164)
                continue
            try:
                result = mark_held_number_released(
                    supabase,
                    phone_number=e164,
                    telnyx_phone_number_id=tid,
                )
            except Exception as e:
                errors.append(f"{e164}: detach {e}")
                continue
            if not result.get("matched"):
                errors.append(f"{e164}: db not matched after detach")
                continue
            email = (result.get("owner_email") or "").strip()
            if email:
                try:
                    notify_customer_number_released(owner_email=email, phone_number=e164)
                except Exception as e:
                    logger.warning("[cron/release-held] customer email failed: %s", e)
            released.append(e164)
            logger.warning(
                "[cron/release-held] detached phone=%s telnyx_id=%s user=%s (kept on Telnyx)",
                e164,
                tid,
                uid,
            )

    return {
        "released": released,
        "skipped": skipped,
        "errors": errors,
        "hold_hours": hold_hours,
    }
