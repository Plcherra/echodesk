"""Phone lifecycle helpers: pending release after soft-delete and same-business reclaim."""

from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta, timezone
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


def _row_e164(row: dict[str, Any]) -> Optional[str]:
    for key in ("inbound_phone_number", "telnyx_phone_number", "phone_number"):
        e164 = normalize_to_e164(str(row.get(key) or ""))
        if e164:
            return e164
    return None


def find_reclaimable_number_for_business(
    supabase: Any,
    business_id: str,
    preferred_e164: str | None = None,
) -> Optional[dict[str, str]]:
    """
    Soft-deleted receptionist on this business that still holds a Telnyx DID.

    If preferred_e164 is set, only that number is returned.
    Returns {receptionist_id, telnyx_id, e164} or None.
    """
    bid = (business_id or "").strip()
    if not bid:
        return None
    want = normalize_to_e164(str(preferred_e164 or "")) or None
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

    fallback: Optional[dict[str, str]] = None
    for row in res.data or []:
        tid = str(row.get("telnyx_phone_number_id") or "").strip()
        e164 = _row_e164(row)
        if not (tid and e164):
            continue
        found = {
            "receptionist_id": str(row.get("id") or ""),
            "telnyx_id": tid,
            "e164": e164,
        }
        if want and e164 == want:
            return found
        if fallback is None:
            fallback = found
    if want:
        return None
    return fallback


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
    Held business lines for this user (no active receptionist).

    Canonical source is business_phone_numbers. Leftover DIDs still sitting on
    soft-deleted receptionist rows are included once so ops can release them.
    """
    uid = (user_id or "").strip()
    if not uid:
        return []

    seen: set[str] = set()
    out: list[dict[str, Any]] = []

    try:
        businesses = (
            supabase.table("businesses")
            .select("id")
            .eq("owner_user_id", uid)
            .execute()
        )
    except Exception as e:
        logger.warning("pending-release businesses failed user_id=%s: %s", uid, e)
        businesses = None

    for biz in (businesses.data or []) if businesses else []:
        bid = str(biz.get("id") or "").strip()
        if not bid:
            continue
        try:
            active = (
                supabase.table("receptionists")
                .select("id")
                .eq("business_id", bid)
                .eq("status", "active")
                .eq("active", True)
                .is_("deleted_at", "null")
                .limit(1)
                .execute()
            )
            if active.data:
                continue
            line = (
                supabase.table("business_phone_numbers")
                .select("phone_number_e164, telnyx_number_id")
                .eq("business_id", bid)
                .limit(1)
                .execute()
            )
            row = (line.data or [None])[0] or {}
            e164 = normalize_to_e164(str(row.get("phone_number_e164") or ""))
            tid = str(row.get("telnyx_number_id") or "").strip()
            if not e164 or not tid or e164 in seen:
                continue
            seen.add(e164)
            out.append(
                {
                    "receptionist_id": None,
                    "receptionist_name": None,
                    "business_id": bid,
                    "phone_number": e164,
                    "phone_display": format_phone_display(e164),
                    "telnyx_phone_number_id": tid,
                    "deleted_at": None,
                    "status": "release_pending",
                }
            )
        except Exception as e:
            logger.warning("pending-release canonical failed business_id=%s: %s", bid, e)

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
        return out

    for row in res.data or []:
        tid = str(row.get("telnyx_phone_number_id") or "").strip()
        e164 = _row_e164(row)
        if not e164 or e164 in seen:
            continue
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


def mark_held_number_released(
    supabase: Any,
    *,
    phone_number: str | None = None,
    telnyx_phone_number_id: str | None = None,
) -> dict[str, Any]:
    """
    After ops removes a DID from Telnyx: detach it from soft-deleted rows and
    clear the canonical business line if it still points at this number.

    Returns {matched, phone_number, telnyx_phone_number_id, owner_user_id,
             owner_email, business_ids, detached_receptionist_ids}.
    """
    want_e164 = normalize_to_e164(str(phone_number or "")) or None
    want_tid = (telnyx_phone_number_id or "").strip() or None
    if not want_e164 and not want_tid:
        return {"matched": False}

    try:
        res = (
            supabase.table("receptionists")
            .select(
                "id, user_id, business_id, inbound_phone_number, telnyx_phone_number, "
                "telnyx_phone_number_id, phone_number, deleted_at"
            )
            .not_.is_("deleted_at", "null")
            .limit(100)
            .execute()
        )
    except Exception as e:
        logger.warning("mark_held_number_released lookup failed: %s", e)
        return {"matched": False, "error": str(e)}

    detached: list[str] = []
    business_ids: set[str] = set()
    owner_user_id: str | None = None
    resolved_e164 = want_e164
    resolved_tid = want_tid

    for row in res.data or []:
        tid = str(row.get("telnyx_phone_number_id") or "").strip()
        e164 = _row_e164(row)
        hit = False
        if want_tid and tid and tid == want_tid:
            hit = True
        if want_e164 and e164 and e164 == want_e164:
            hit = True
        if not hit:
            continue
        rid = str(row.get("id") or "")
        if rid:
            try:
                detach_phone_from_receptionist(supabase, rid)
                detached.append(rid)
            except Exception as ex:
                logger.warning("detach on release failed id=%s: %s", rid, ex)
        bid = str(row.get("business_id") or "").strip()
        if bid:
            business_ids.add(bid)
        if not owner_user_id:
            owner_user_id = str(row.get("user_id") or "").strip() or None
        resolved_e164 = resolved_e164 or e164
        resolved_tid = resolved_tid or (tid or None)

    try:
        lines = (
            supabase.table("business_phone_numbers")
            .select("business_id, phone_number_e164, telnyx_number_id")
            .execute()
        )
        for row in lines.data or []:
            line_e164 = normalize_to_e164(str(row.get("phone_number_e164") or ""))
            line_tid = str(row.get("telnyx_number_id") or "").strip()
            hit = bool(
                (want_e164 and line_e164 == want_e164)
                or (want_tid and line_tid and line_tid == want_tid)
            )
            if not hit:
                continue
            bid = str(row.get("business_id") or "").strip()
            if bid:
                business_ids.add(bid)
            resolved_e164 = resolved_e164 or line_e164
            resolved_tid = resolved_tid or (line_tid or None)
            if not owner_user_id and bid:
                try:
                    bres = (
                        supabase.table("businesses")
                        .select("owner_user_id")
                        .eq("id", bid)
                        .limit(1)
                        .execute()
                    )
                    if bres.data:
                        owner_user_id = str(
                            (bres.data[0] or {}).get("owner_user_id") or ""
                        ).strip() or None
                except Exception:
                    pass
    except Exception as e:
        logger.warning("mark_held_number_released canonical scan failed: %s", e)

    for bid in list(business_ids):
        try:
            line = (
                supabase.table("business_phone_numbers")
                .select("phone_number_e164, telnyx_number_id")
                .eq("business_id", bid)
                .limit(1)
                .execute()
            )
            row = (line.data or [None])[0] or {}
            line_e164 = normalize_to_e164(str(row.get("phone_number_e164") or ""))
            line_tid = str(row.get("telnyx_number_id") or "").strip()
            matches = bool(
                (resolved_e164 and line_e164 == resolved_e164)
                or (resolved_tid and line_tid and line_tid == resolved_tid)
            )
            if not matches:
                continue
            from communication.ensure import upsert_canonical_business_phone

            upsert_canonical_business_phone(
                supabase,
                bid,
                phone_number_e164=None,
                telnyx_number_id=None,
            )
        except Exception as ex:
            logger.warning("clear business line on release failed bid=%s: %s", bid, ex)

    owner_email = None
    if owner_user_id:
        try:
            ures = (
                supabase.table("users")
                .select("email")
                .eq("id", owner_user_id)
                .limit(1)
                .execute()
            )
            if ures.data:
                owner_email = (ures.data[0] or {}).get("email")
        except Exception as ex:
            logger.warning("owner email on release failed: %s", ex)

    return {
        "matched": bool(detached) or bool(business_ids),
        "phone_number": resolved_e164,
        "telnyx_phone_number_id": resolved_tid,
        "owner_user_id": owner_user_id,
        "owner_email": owner_email,
        "business_ids": sorted(business_ids),
        "detached_receptionist_ids": detached,
    }


HOLD_HOURS = 48


def _parse_ts(raw: Any) -> datetime | None:
    if not raw:
        return None
    s = str(raw).strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def can_purchase_extra_number(inventory: list[dict[str, Any]]) -> bool:
    """True when the account has exactly one held DID and no live line (1+1 cap)."""
    e164s = {str(i.get("e164") or "") for i in inventory if i.get("e164")}
    live = [i for i in inventory if i.get("live")]
    return len(e164s) == 1 and len(live) == 0


def collect_account_phone_inventory(
    supabase: Any, user_id: str
) -> list[dict[str, Any]]:
    """Unique DIDs on this user's businesses: live vs held, with held_at."""
    uid = (user_id or "").strip()
    if not uid:
        return []
    by_e164: dict[str, dict[str, Any]] = {}

    def _add(
        *,
        e164: str,
        telnyx_id: str | None,
        live: bool,
        held_at: datetime | None,
        business_id: str | None,
        owner_user_id: str,
    ) -> None:
        cur = by_e164.get(e164)
        if cur is None:
            by_e164[e164] = {
                "e164": e164,
                "telnyx_id": (telnyx_id or "").strip() or None,
                "live": live,
                "held_at": held_at,
                "business_id": business_id,
                "owner_user_id": owner_user_id,
            }
            return
        cur["live"] = bool(cur["live"] or live)
        if telnyx_id and not cur.get("telnyx_id"):
            cur["telnyx_id"] = telnyx_id
        if held_at and (cur.get("held_at") is None or held_at > cur["held_at"]):
            cur["held_at"] = held_at

    try:
        businesses = (
            supabase.table("businesses")
            .select("id")
            .eq("owner_user_id", uid)
            .execute()
        )
    except Exception as e:
        logger.warning("inventory businesses failed user_id=%s: %s", uid, e)
        return []

    for biz in businesses.data or []:
        bid = str(biz.get("id") or "").strip()
        if not bid:
            continue
        latest_delete: datetime | None = None
        live_e164: set[str] = set()
        try:
            recs = (
                supabase.table("receptionists")
                .select(
                    "id, user_id, inbound_phone_number, telnyx_phone_number, "
                    "telnyx_phone_number_id, phone_number, deleted_at, status, active"
                )
                .eq("business_id", bid)
                .execute()
            )
        except Exception as e:
            logger.warning("inventory recs failed business_id=%s: %s", bid, e)
            recs = None
        for row in (recs.data or []) if recs else []:
            e164 = _row_e164(row)
            tid = str(row.get("telnyx_phone_number_id") or "").strip() or None
            deleted_at = _parse_ts(row.get("deleted_at"))
            is_live = (
                row.get("deleted_at") in (None, "")
                and row.get("status") == "active"
                and row.get("active") is True
            )
            if deleted_at and (latest_delete is None or deleted_at > latest_delete):
                latest_delete = deleted_at
            if is_live and e164:
                live_e164.add(e164)
                _add(
                    e164=e164,
                    telnyx_id=tid,
                    live=True,
                    held_at=None,
                    business_id=bid,
                    owner_user_id=uid,
                )
            elif e164 and not is_live:
                _add(
                    e164=e164,
                    telnyx_id=tid,
                    live=False,
                    held_at=deleted_at,
                    business_id=bid,
                    owner_user_id=uid,
                )
        try:
            line = (
                supabase.table("business_phone_numbers")
                .select("phone_number_e164, telnyx_number_id")
                .eq("business_id", bid)
                .limit(1)
                .execute()
            )
            row = (line.data or [None])[0] or {}
            e164 = normalize_to_e164(str(row.get("phone_number_e164") or ""))
            tid = str(row.get("telnyx_number_id") or "").strip() or None
            if e164:
                live = e164 in live_e164
                _add(
                    e164=e164,
                    telnyx_id=tid,
                    live=live,
                    held_at=None if live else latest_delete,
                    business_id=bid,
                    owner_user_id=uid,
                )
        except Exception as e:
            logger.warning("inventory canonical failed business_id=%s: %s", bid, e)

    for item in by_e164.values():
        if item.get("live"):
            item["held_at"] = None
    return list(by_e164.values())


def expired_held_numbers(
    inventory: list[dict[str, Any]],
    *,
    now: datetime | None = None,
    hold_hours: int = HOLD_HOURS,
) -> list[dict[str, Any]]:
    now_dt = now or datetime.now(timezone.utc)
    if now_dt.tzinfo is None:
        now_dt = now_dt.replace(tzinfo=timezone.utc)
    cutoff = timedelta(hours=max(1, hold_hours))
    out: list[dict[str, Any]] = []
    for item in inventory:
        if item.get("live"):
            continue
        held_at = item.get("held_at")
        if not isinstance(held_at, datetime):
            continue
        if held_at.tzinfo is None:
            held_at = held_at.replace(tzinfo=timezone.utc)
        if now_dt - held_at >= cutoff:
            out.append(item)
    return out


def park_did_on_latest_deleted(
    supabase: Any,
    business_id: str,
    *,
    e164: str,
    telnyx_id: str | None,
) -> bool:
    """Keep a replaced DID on the latest deleted receptionist so cron can release it."""
    bid = (business_id or "").strip()
    phone = normalize_to_e164(e164 or "")
    if not bid or not phone:
        return False
    try:
        res = (
            supabase.table("receptionists")
            .select("id")
            .eq("business_id", bid)
            .not_.is_("deleted_at", "null")
            .order("deleted_at", desc=True)
            .limit(1)
            .execute()
        )
    except Exception as e:
        logger.warning("park DID lookup failed business_id=%s: %s", bid, e)
        return False
    rid = str(((res.data or [{}])[0] or {}).get("id") or "").strip()
    if not rid:
        return False
    try:
        supabase.table("receptionists").update(
            {
                "telnyx_phone_number_id": (telnyx_id or "").strip() or None,
                "telnyx_phone_number": phone,
                "inbound_phone_number": phone,
                "phone_number": phone,
            }
        ).eq("id", rid).execute()
        return True
    except Exception as e:
        logger.warning("park DID update failed id=%s: %s", rid, e)
        return False
