"""Internal ops: mark a held DID fully released after Telnyx deletion."""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import JSONResponse

from config import settings
from supabase_client import create_service_role_client
from telnyx.phone_lifecycle import mark_held_number_released
from utils.internal_notify import notify_customer_number_released
from utils.phone import normalize_to_e164

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/internal/phone-numbers", tags=["internal-phone-release"])


def _require_internal(authorization: Optional[str]) -> None:
    key = (settings.internal_api_key or "").strip()
    if not key:
        raise HTTPException(status_code=503, detail="INTERNAL_API_KEY not configured")
    if (authorization or "") != f"Bearer {key}":
        raise HTTPException(status_code=401, detail="Unauthorized")


@router.post("/release")
async def post_phone_number_release(
    request: Request,
    authorization: Optional[str] = Header(None, alias="Authorization"),
):
    """Call this after deleting the DID in Telnyx. Clears held UI and emails the customer."""
    _require_internal(authorization)
    try:
        body = await request.json()
    except Exception:
        body = {}

    phone = normalize_to_e164(str(body.get("phone_number") or "")) or None
    telnyx_id = str(body.get("telnyx_phone_number_id") or "").strip() or None
    if not phone and not telnyx_id:
        return JSONResponse(
            {"error": "phone_number or telnyx_phone_number_id is required"},
            status_code=400,
        )

    supabase = create_service_role_client()
    result = mark_held_number_released(
        supabase,
        phone_number=phone,
        telnyx_phone_number_id=telnyx_id,
    )
    if not result.get("matched"):
        return JSONResponse(
            {
                "error": "No held number matched. Check the E.164 / Telnyx id.",
                **{k: v for k, v in result.items() if k != "error"},
            },
            status_code=404,
        )

    emailed = False
    owner_email = (result.get("owner_email") or "").strip()
    released_phone = result.get("phone_number") or phone
    if owner_email and released_phone:
        try:
            emailed = notify_customer_number_released(
                owner_email=owner_email,
                phone_number=str(released_phone),
            )
        except Exception as ex:
            logger.warning("[internal phone-release] customer email failed: %s", ex)

    logger.warning(
        "[ops] PHONE_NUMBER_RELEASED phone=%s telnyx_id=%s detached=%s emailed=%s",
        released_phone,
        result.get("telnyx_phone_number_id"),
        result.get("detached_receptionist_ids"),
        emailed,
    )
    return {
        "success": True,
        "customer_emailed": emailed,
        **result,
    }
