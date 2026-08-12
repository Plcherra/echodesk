"""Business-first communication: canonical line in business_phone_numbers; receptionist phone fields are mirrors for voice routing."""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any

logger = logging.getLogger(__name__)

# -----------------------------------------------------------------------------
# Implementation rules (do not break):
# 1) business_phone_numbers is the only canonical store for the shared Telnyx line.
#    Use upsert_canonical_business_phone / mark_business_phone_line_failed — do not scatter updates.
# 2) receptionists.telnyx_* / inbound_phone_number / phone_number are compatibility mirrors for
#    telnyx/receptionist_lookup and webhooks. Use mirror_business_phone_to_receptionists.
# -----------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.utcnow().isoformat() + "Z"


def receptionist_mode_to_business_mode(mode: str | None) -> str:
    m = (mode or "personal").strip().lower()
    return "team" if m == "business" else "solo"


def upsert_canonical_business_phone(
    supabase: Any,
    business_id: str,
    *,
    phone_number_e164: str | None,
    telnyx_number_id: str | None,
) -> None:
    """
    Sanctioned write path for the business line (business_phone_numbers).
    All Telnyx/E.164 updates for the shared number should go through here.
    """
    tid = (telnyx_number_id or "").strip() or None
    e164 = (phone_number_e164 or "").strip() or None
    if tid and e164:
        status = "active"
    elif e164 or tid:
        status = "provisioning"
    else:
        status = "not_started"

    payload = {
        "business_id": business_id,
        "provider": "telnyx",
        "phone_number_e164": e164,
        "telnyx_number_id": tid,
        "status": status,
        "updated_at": _now_iso(),
    }
    supabase.table("business_phone_numbers").upsert(payload, on_conflict="business_id").execute()


def mark_business_phone_line_failed(supabase: Any, business_id: str) -> None:
    """No active assistants / line invalid — canonical row reflects failed (clears stale IDs)."""
    supabase.table("business_phone_numbers").upsert(
        {
            "business_id": business_id,
            "provider": "telnyx",
            "phone_number_e164": None,
            "telnyx_number_id": None,
            "status": "failed",
            "updated_at": _now_iso(),
        },
        on_conflict="business_id",
    ).execute()


def ensure_business_phone_not_started(supabase: Any, business_id: str) -> None:
    """Create a clean first-time phone row without masking real provisioning failures."""
    res = supabase.table("business_phone_numbers").select("*").eq("business_id", business_id).limit(1).execute()
    row = (res.data or [None])[0]
    if row and (row.get("status") or "").strip() == "failed":
        return
    upsert_canonical_business_phone(
        supabase,
        business_id,
        phone_number_e164=None,
        telnyx_number_id=None,
    )


def mirror_business_phone_to_receptionists(supabase: Any, business_id: str) -> None:
    """
    Push canonical business_phone_numbers onto all active receptionists for this business.
    Receptionist phone columns are compatibility mirrors only (voice DID routing).
    """
    pr = supabase.table("business_phone_numbers").select("*").eq("business_id", business_id).limit(1).execute()
    row = (pr.data or [None])[0]
    if not row:
        return

    e164 = ((row.get("phone_number_e164") or "").strip() or None) or ""
    tid = ((row.get("telnyx_number_id") or "").strip() or None) or None
    display_num = e164 or None
    res = (
        supabase.table("receptionists")
        .select("id")
        .eq("business_id", business_id)
        .eq("status", "active")
        .eq("active", True)
        .is_("deleted_at", "null")
        .execute()
    )
    now = _now_iso()
    mirror_payload = {
        # Compatibility mirror only — canonical values live in business_phone_numbers.
        "phone_number": display_num,
        "inbound_phone_number": display_num,
        "telnyx_phone_number_id": tid,
        "telnyx_phone_number": display_num,
        "updated_at": now,
    }
    for r in res.data or []:
        rid = r.get("id")
        if rid:
            supabase.table("receptionists").update(mirror_payload).eq("id", rid).execute()


def list_businesses_for_owner(supabase: Any, owner_user_id: str) -> list[dict[str, Any]]:
    r = (
        supabase.table("businesses")
        .select("id, owner_user_id, name, mode, primary_receptionist_id, created_at")
        .eq("owner_user_id", owner_user_id)
        .order("created_at")
        .execute()
    )
    return list(r.data or [])


def get_default_business_for_owner(supabase: Any, owner_user_id: str) -> dict[str, Any] | None:
    rows = list_businesses_for_owner(supabase, owner_user_id)
    return rows[0] if rows else None


def list_active_receptionists_for_business(supabase: Any, business_id: str) -> list[dict[str, Any]]:
    res = (
        supabase.table("receptionists")
        .select(
            "id, user_id, created_at, mode, status, active, deleted_at, business_id, "
            "telnyx_phone_number_id, telnyx_phone_number, inbound_phone_number, phone_number"
        )
        .eq("business_id", business_id)
        .eq("status", "active")
        .eq("active", True)
        .is_("deleted_at", "null")
        .order("created_at")
        .execute()
    )
    return list(res.data or [])


def _backfill_canonical_from_primary_receptionist(
    supabase: Any, business_id: str, primary: dict[str, Any]
) -> None:
    """TODO(compat): Legacy rows where receptionist predates canonical table; remove when fully migrated."""
    e164 = (
        (primary.get("telnyx_phone_number") or "").strip()
        or (primary.get("inbound_phone_number") or "").strip()
        or (primary.get("phone_number") or "").strip()
        or None
    )
    tid = (primary.get("telnyx_phone_number_id") or "").strip() or None
    upsert_canonical_business_phone(
        supabase,
        business_id,
        phone_number_e164=e164,
        telnyx_number_id=tid,
    )
    mirror_business_phone_to_receptionists(supabase, business_id)


def _ensure_child_rows(supabase: Any, business_id: str) -> None:
    existing = (
        supabase.table("sms_campaigns").select("id").eq("business_id", business_id).limit(1).execute()
    )
    if not (existing.data or []):
        supabase.table("sms_campaigns").insert(
            {
                "business_id": business_id,
                "status": "not_started",
                "created_at": _now_iso(),
                "updated_at": _now_iso(),
            }
        ).execute()

    wa = (
        supabase.table("whatsapp_accounts").select("id").eq("business_id", business_id).limit(1).execute()
    )
    if not (wa.data or []):
        supabase.table("whatsapp_accounts").insert(
            {
                "business_id": business_id,
                "status": "not_connected",
                "created_at": _now_iso(),
                "updated_at": _now_iso(),
            }
        ).execute()


def ensure_business_communication(supabase: Any, business_id: str) -> dict[str, Any] | None:
    """
    Per-business: set primary receptionist (oldest active for this business), sync name for default
    business only, keep canonical phone + mirrors aligned, ensure sms/whatsapp rows.
    """
    bres = supabase.table("businesses").select("*").eq("id", business_id).limit(1).execute()
    rows = bres.data or []
    if not rows:
        return None
    business = rows[0]
    owner_id = str(business["owner_user_id"])

    recs = list_active_receptionists_for_business(supabase, business_id)
    default_business = get_default_business_for_owner(supabase, owner_id)
    default_id = default_business["id"] if default_business else None
    now = _now_iso()

    if not recs:
        supabase.table("businesses").update(
            {"primary_receptionist_id": None, "updated_at": now}
        ).eq("id", business_id).execute()
        # Keep a held DID on the business so the owner can reclaim it and we
        # do not buy another number. Only seed an empty row when there is none.
        phone_res = (
            supabase.table("business_phone_numbers")
            .select("telnyx_number_id, phone_number_e164")
            .eq("business_id", business_id)
            .limit(1)
            .execute()
        )
        phone = (phone_res.data or [None])[0] or {}
        has_held = bool(
            (phone.get("telnyx_number_id") or "").strip()
            and (phone.get("phone_number_e164") or "").strip()
        )
        if not has_held:
            ensure_business_phone_not_started(supabase, business_id)
        _ensure_child_rows(supabase, business_id)
        return {**business, "primary_receptionist_id": None}

    primary = recs[0]
    primary_id = primary["id"]
    business_mode = receptionist_mode_to_business_mode(primary.get("mode"))

    ures = (
        supabase.table("users")
        .select("business_name")
        .eq("id", owner_id)
        .single()
        .execute()
    )
    u = ures.data or {}
    biz_name = (u.get("business_name") or "").strip() or None

    updates: dict[str, Any] = {
        "primary_receptionist_id": primary_id,
        "mode": business_mode,
        "updated_at": now,
    }
    if default_id == business_id and biz_name is not None:
        updates["name"] = biz_name

    supabase.table("businesses").update(updates).eq("id", business_id).execute()

    phone_res = supabase.table("business_phone_numbers").select("*").eq("business_id", business_id).limit(1).execute()
    phone = (phone_res.data or [None])[0]

    tid_canon = ((phone or {}).get("telnyx_number_id") or "").strip()
    e164_canon = ((phone or {}).get("phone_number_e164") or "").strip()
    has_canon = bool(tid_canon and e164_canon)

    if not has_canon:
        _backfill_canonical_from_primary_receptionist(supabase, business_id, primary)
    else:
        mirror_business_phone_to_receptionists(supabase, business_id)

    _ensure_child_rows(supabase, business_id)
    return {**business, **updates}


def resolve_target_business_for_new_receptionist(
    supabase: Any, owner_user_id: str, body_business_id: str | None
) -> dict[str, Any]:
    """Pick or create the business row before inserting a receptionist."""
    if body_business_id:
        r = (
            supabase.table("businesses")
            .select("id, owner_user_id, name, mode, primary_receptionist_id, created_at")
            .eq("id", body_business_id)
            .eq("owner_user_id", owner_user_id)
            .limit(1)
            .execute()
        )
        found = r.data or []
        if not found:
            raise ValueError("invalid_business")
        return found[0]

    existing = list_businesses_for_owner(supabase, owner_user_id)
    if existing:
        u = (
            supabase.table("users")
            .select("active_business_id")
            .eq("id", owner_user_id)
            .single()
            .execute()
        )
        aid = (u.data or {}).get("active_business_id")
        if aid:
            for b in existing:
                if str(b["id"]) == str(aid):
                    return b
        return existing[0]

    ures = (
        supabase.table("users")
        .select("business_name")
        .eq("id", owner_user_id)
        .single()
        .execute()
    )
    name = ((ures.data or {}).get("business_name") or "").strip() or None
    now = _now_iso()
    ins = (
        supabase.table("businesses")
        .insert(
            {
                "owner_user_id": owner_user_id,
                "name": name,
                "mode": "solo",
                "created_at": now,
                "updated_at": now,
            }
        )
        .execute()
    )
    row = (ins.data or [None])[0]
    if row:
        return row
    refetch = get_default_business_for_owner(supabase, owner_user_id)
    if not refetch:
        raise RuntimeError("failed_to_create_business")
    return refetch


def resolve_business_for_communication(
    supabase: Any,
    owner_user_id: str,
    query_business_id: str | None,
) -> tuple[dict[str, Any] | None, bool]:
    """
    Returns (business_row, is_default_business).
    TODO(multi-business): Prefer users.active_business_id when query_business_id is absent; today
    that is applied inside this helper via users.active_business_id, then fallback to oldest.
    """
    default_b = get_default_business_for_owner(supabase, owner_user_id)
    if not default_b:
        return None, True

    if query_business_id:
        r = (
            supabase.table("businesses")
            .select("id, owner_user_id, name, mode, primary_receptionist_id, created_at")
            .eq("id", query_business_id)
            .eq("owner_user_id", owner_user_id)
            .limit(1)
            .execute()
        )
        found = r.data or []
        if not found:
            return None, False
        b = found[0]
        is_def = b["id"] == default_b["id"]
        return b, is_def

    u = (
        supabase.table("users")
        .select("active_business_id")
        .eq("id", owner_user_id)
        .single()
        .execute()
    )
    aid = (u.data or {}).get("active_business_id")
    if aid:
        r = (
            supabase.table("businesses")
            .select("id, owner_user_id, name, mode, primary_receptionist_id, created_at")
            .eq("id", aid)
            .eq("owner_user_id", owner_user_id)
            .limit(1)
            .execute()
        )
        found = r.data or []
        if found:
            b = found[0]
            is_def = b["id"] == default_b["id"]
            return b, is_def

    return default_b, True


# Backwards-compatible names -------------------------------------------------

def get_business_by_owner(supabase: Any, owner_user_id: str) -> dict[str, Any] | None:
    """Deprecated: use resolve_business_for_communication or get_default_business_for_owner."""
    return get_default_business_for_owner(supabase, owner_user_id)


def ensure_communication_for_user_after_receptionist_change(
    supabase: Any, owner_user_id: str
) -> dict[str, Any] | None:
    """
    Legacy entrypoint: re-sync all businesses owned by this user (repair / old callers).
    Prefer ensure_business_communication(business_id) for new code.
    """
    businesses = list_businesses_for_owner(supabase, owner_user_id)
    last: dict[str, Any] | None = None
    for b in businesses:
        last = ensure_business_communication(supabase, str(b["id"])) or last
    return last


def refresh_business_after_primary_receptionist_removed(
    supabase: Any,
    business_id: str,
) -> None:
    """After soft-delete: repoint primary and re-mirror canonical line for this business."""
    ensure_business_communication(supabase, business_id)


def refresh_business_communication(supabase: Any, business_id: str) -> None:
    """Alias for ensure after delete or external change."""
    ensure_business_communication(supabase, business_id)
