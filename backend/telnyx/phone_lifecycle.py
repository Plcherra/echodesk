"""Phone lifecycle helpers: pending release after soft-delete and same-business reclaim."""

from __future__ import annotations

import logging
import re
from typing import Any, Optional

from utils.phone import normalize_to_e164

logger = logging.getLogger(__name__)


def format_phone_display(e164: str | None) -> str:
    """Pretty US/CA style display for held numbers (+13105847719 → +1 310-584-7719)."""
    n = normalize_to_e164(str(e164 or "")) or (e164 or "").strip()
    if not n:
        return ""
    digits = re.sub(r"\D", "", n)
    if len(digits) == 11 and digits.startswith("1"):
        return f"+1 {digits[1:4]}-{digits[4:7]}-{digits[7:]}"
    if len(digits) == 10:
        return f"+1 {digits[0:3]}-{digits[3:6]}-{digits[6:]}"
    return n if n.startswith("+") else f"+{digits}"


def find_reclaimable_number_for_business(
    supabase: Any,
    business_id: str,
) -> Optional[dict[str, str]]:
    """
    Soft-deleted receptionist on this business that still holds a Telnyx DID.

    Returns {receptionist_id, telnyx_id, e164} or None.
    """
    bid = (business_id or "").strip()
    if not bid:
        return None
    try:
        res = (
            supabase.table("receptionists")
            .select(
                "id, inbound_phone_number, telnyx_phone_number, "
                "telnyx_phone_number_id, phone_number, deleted_at"
            )
            .eq("business_id", bid)
            .not_.is_("deleted_at", "null")
            .order("deleted_at", desc=True)
            .limit(20)
            .execute()
        )
    except Exception as e:
        logger.warning("reclaimable number lookup failed business_id=%s: %s", bid, e)
        return None

    for row in res.data or []:
        tid = str(row.get("telnyx_phone_number_id") or "").strip()
        e164 = None
        for key in ("inbound_phone_number", "telnyx_phone_number", "phone_number"):
            e164 = normalize_to_e164(str(row.get(key) or ""))
            if e164:
                break
        if tid and e164:
            return {
                "receptionist_id": str(row.get("id") or ""),
                "telnyx_id": tid,
                "e164": e164,
            }
    return None


def detach_phone_from_receptionist(supabase: Any, receptionist_id: str) -> None:
    """Clear DID mirrors on a soft-deleted row after reclaim so inventory is free."""
    rid = (receptionist_id or "").strip()
    if not rid:
        return
    supabase.table("receptionists").update(
        {
            "telnyx_phone_number_id": None,
            "telnyx_phone_number": None,
            "inbound_phone_number": None,
            "phone_number": None,
        }
    ).eq("id", rid).execute()


def list_pending_release_numbers_for_user(
    supabase: Any,
    user_id: str,
) -> list[dict[str, Any]]:
    """
    Soft-deleted assistants still holding a DID for this user.

    These are reclaimable on create (same business) until ops releases them.
    """
    uid = (user_id or "").strip()
    if not uid:
        return []
    try:
        res = (
            supabase.table("receptionists")
            .select(
                "id, name, business_id, inbound_phone_number, telnyx_phone_number, "
                "telnyx_phone_number_id, phone_number, deleted_at"
            )
            .eq("user_id", uid)
            .not_.is_("deleted_at", "null")
            .order("deleted_at", desc=True)
            .limit(50)
            .execute()
        )
    except Exception as e:
        logger.warning("pending-release list failed user_id=%s: %s", uid, e)
        return []

    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for row in res.data or []:
        tid = str(row.get("telnyx_phone_number_id") or "").strip()
        e164 = None
        for key in ("inbound_phone_number", "telnyx_phone_number", "phone_number"):
            e164 = normalize_to_e164(str(row.get(key) or ""))
            if e164:
                break
        if not e164:
            continue
        if e164 in seen:
            continue
        # Skip if another active receptionist already uses this number.
        try:
            active = (
                supabase.table("receptionists")
                .select("id")
                .eq("user_id", uid)
                .eq("status", "active")
                .eq("active", True)
                .is_("deleted_at", "null")
                .eq("inbound_phone_number", e164)
                .limit(1)
                .execute()
            )
            if active.data:
                continue
        except Exception:
            pass
        seen.add(e164)
        out.append(
            {
                "receptionist_id": row.get("id"),
                "receptionist_name": row.get("name"),
                "business_id": row.get("business_id"),
                "phone_number": e164,
                "phone_display": format_phone_display(e164),
                "telnyx_phone_number_id": tid or None,
                "deleted_at": row.get("deleted_at"),
                "status": "release_pending",
            }
        )
    return out
