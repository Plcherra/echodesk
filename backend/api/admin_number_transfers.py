"""Internal ops: update number transfer request status (INTERNAL_API_KEY)."""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import JSONResponse

from config import settings
from supabase_client import create_service_role_client
from utils.internal_notify import notify_customer_number_transfer_status

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/internal/number-transfers", tags=["internal-number-transfers"])

ALLOWED_STATUSES = frozenset({"porting", "completed", "rejected", "cancelled"})


def _require_internal(authorization: Optional[str]) -> None:
    key = (settings.internal_api_key or "").strip()
    if not key:
        raise HTTPException(status_code=503, detail="INTERNAL_API_KEY not configured")
    if (authorization or "") != f"Bearer {key}":
        raise HTTPException(status_code=401, detail="Unauthorized")


@router.patch("/{request_id}")
async def patch_number_transfer(
    request_id: str,
    request: Request,
    authorization: Optional[str] = Header(None, alias="Authorization"),
):
    _require_internal(authorization)

    try:
        body = await request.json()
    except Exception:
        body = {}

    status = (body.get("status") or "").strip()
    if status not in ALLOWED_STATUSES:
        return JSONResponse(
            {
                "error": f"status must be one of: {', '.join(sorted(ALLOWED_STATUSES))}",
            },
            status_code=400,
        )

    ops_note = (body.get("ops_note") or "").strip() or None
    supabase = create_service_role_client()

    existing = (
        supabase.table("number_transfer_requests")
        .select(
            "id, user_id, phone_number_e164, status, carrier_or_provider, number_kind"
        )
        .eq("id", request_id)
        .limit(1)
        .execute()
    )
    if not existing.data:
        return JSONResponse({"error": "Not found"}, status_code=404)

    row = existing.data[0]
    now = datetime.utcnow().isoformat() + "Z"
    updates: dict = {"status": status, "updated_at": now}
    if ops_note is not None:
        updates["ops_note"] = ops_note

    supabase.table("number_transfer_requests").update(updates).eq("id", request_id).execute()

    if status in ("completed", "rejected"):
        owner_email = None
        try:
            ures = (
                supabase.table("users")
                .select("email")
                .eq("id", row["user_id"])
                .limit(1)
                .execute()
            )
            if ures.data:
                owner_email = (ures.data[0] or {}).get("email")
        except Exception as ex:
            logger.warning("[internal number-transfers] load owner email failed: %s", ex)

        if owner_email:
            try:
                notify_customer_number_transfer_status(
                    owner_email=str(owner_email),
                    phone_number=str(row.get("phone_number_e164") or ""),
                    status=status,
                    ops_note=ops_note,
                )
            except Exception as ex:
                logger.warning("[internal number-transfers] customer email failed: %s", ex)

    return {
        "success": True,
        "id": request_id,
        "status": status,
        "previous_status": row.get("status"),
    }
