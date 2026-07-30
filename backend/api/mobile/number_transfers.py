"""Mobile API: number transfer evaluation requests."""

from __future__ import annotations

import logging
import re
from datetime import datetime
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from api.auth import get_user_from_request
from utils.internal_notify import notify_number_transfer_requested
from utils.phone import normalize_to_e164

logger = logging.getLogger(__name__)
router = APIRouter(tags=["mobile-number-transfers"])

OPEN_STATUSES = ("pending_review", "porting")
VALID_KINDS = ("mobile_carrier", "voip_internet")

_PHONE_RE = re.compile(r"^\+\d{10,15}$")


def _require_auth(request: Request) -> tuple[dict | None, Any]:
    user, supabase = get_user_from_request(request)
    if not user or not supabase:
        return (None, None)
    return (user, supabase)


def _serialize(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row.get("id"),
        "phone_number_e164": row.get("phone_number_e164"),
        "number_kind": row.get("number_kind"),
        "carrier_or_provider": row.get("carrier_or_provider"),
        "customer_note": row.get("customer_note"),
        "status": row.get("status"),
        "business_id": row.get("business_id"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
    }


@router.get("/number-transfers/active")
async def get_active_number_transfer(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    r = (
        supabase.table("number_transfer_requests")
        .select(
            "id, phone_number_e164, number_kind, carrier_or_provider, customer_note, "
            "status, business_id, created_at, updated_at"
        )
        .eq("user_id", user["id"])
        .in_("status", list(OPEN_STATUSES))
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )
    rows = r.data or []
    if not rows:
        return {"request": None}
    return {"request": _serialize(rows[0])}


@router.post("/number-transfers")
async def create_number_transfer(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except Exception:
        body = {}

    raw_phone = (body.get("phone") or body.get("phone_number") or "").strip()
    e164 = normalize_to_e164(raw_phone) or ""
    if not e164 or not _PHONE_RE.match(e164):
        return JSONResponse(
            {"error": "Enter phone with country code (e.g. +15551234567)."},
            status_code=400,
        )

    number_kind = (body.get("number_kind") or "").strip()
    if number_kind not in VALID_KINDS:
        return JSONResponse(
            {
                "error": "Select whether this is a mobile/carrier phone or an internet/VoIP number."
            },
            status_code=400,
        )

    carrier = (body.get("carrier_or_provider") or "").strip()
    if not carrier:
        return JSONResponse(
            {"error": "Tell us the carrier or provider (e.g. T-Mobile, Twilio)."},
            status_code=400,
        )
    if len(carrier) > 120:
        return JSONResponse({"error": "Carrier / provider is too long."}, status_code=400)

    note = (body.get("customer_note") or "").strip() or None
    if note and len(note) > 2000:
        return JSONResponse({"error": "Note is too long."}, status_code=400)

    existing = (
        supabase.table("number_transfer_requests")
        .select("id, status")
        .eq("user_id", user["id"])
        .in_("status", list(OPEN_STATUSES))
        .limit(1)
        .execute()
    )
    if existing.data:
        return JSONResponse(
            {
                "error": "You already have a number transfer under review.",
                "request_id": existing.data[0].get("id"),
            },
            status_code=409,
        )

    owner_email = (user.get("email") or "").strip() or None
    if not owner_email:
        try:
            ures = (
                supabase.table("users")
                .select("email")
                .eq("id", user["id"])
                .limit(1)
                .execute()
            )
            if ures.data:
                owner_email = (ures.data[0] or {}).get("email")
        except Exception:
            pass

    now = datetime.utcnow().isoformat() + "Z"
    insert = {
        "user_id": user["id"],
        "phone_number_e164": e164,
        "number_kind": number_kind,
        "carrier_or_provider": carrier,
        "customer_note": note,
        "status": "pending_review",
        "created_at": now,
        "updated_at": now,
    }
    try:
        ins = supabase.table("number_transfer_requests").insert(insert).execute()
    except Exception as ex:
        logger.warning("[number-transfers] insert failed: %s", ex)
        return JSONResponse(
            {"error": "Could not submit transfer request. Please try again."},
            status_code=500,
        )

    row = (ins.data or [None])[0] if ins.data else None
    if not row:
        # Fallback fetch
        fetch = (
            supabase.table("number_transfer_requests")
            .select(
                "id, phone_number_e164, number_kind, carrier_or_provider, customer_note, "
                "status, business_id, created_at, updated_at"
            )
            .eq("user_id", user["id"])
            .eq("status", "pending_review")
            .order("created_at", desc=True)
            .limit(1)
            .execute()
        )
        row = (fetch.data or [None])[0]

    if not row:
        return JSONResponse(
            {"error": "Could not submit transfer request. Please try again."},
            status_code=500,
        )

    try:
        notify_number_transfer_requested(
            request_id=str(row.get("id")),
            phone_number=e164,
            number_kind=number_kind,
            carrier_or_provider=carrier,
            customer_note=note,
            owner_user_id=str(user["id"]),
            owner_email=owner_email,
            business_id=None,
        )
    except Exception as ex:
        logger.warning("[number-transfers] ops notify failed: %s", ex)

    return {"success": True, "request": _serialize(row)}
