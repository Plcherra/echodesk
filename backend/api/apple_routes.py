"""Apple In-App Purchase verification and App Store Server Notifications V2."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from api.auth import get_user_from_request
from billing.apple_sync import apply_apple_subscription
from billing.apple_verifier import (
    AppleIapConfigError,
    AppleVerificationError,
    fetch_signed_transaction,
    verify_signed_notification,
    verify_signed_renewal,
    verify_signed_transaction,
)
from supabase_client import create_service_role_client

logger = logging.getLogger(__name__)
router = APIRouter(tags=["apple-iap"])


def _json_error(exc: AppleVerificationError) -> JSONResponse:
    return JSONResponse({"error": str(exc)}, status_code=exc.status_code)


def _result_response(result: dict[str, Any]) -> JSONResponse | dict[str, Any]:
    if not result.get("ok"):
        return JSONResponse(
            {"error": result.get("error") or "Could not update the subscription."},
            status_code=int(result.get("status_code") or 400),
        )
    return {
        "ok": True,
        "ignored": bool(result.get("ignored")),
        "reason": result.get("reason"),
        "status": result.get("status"),
        "entitled": result.get("entitled"),
        "product_id": result.get("product_id"),
    }


@router.post("/api/mobile/apple/verify")
async def verify_apple_purchase(request: Request):
    """Verify a StoreKit 2 signed transaction and activate it for the signed-in user."""
    user, _supabase = get_user_from_request(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)

    try:
        signed = (body.get("signed_transaction") or "").strip()
        if not signed:
            transaction_id = (body.get("transaction_id") or "").strip()
            if not transaction_id:
                return JSONResponse(
                    {"error": "signed_transaction or transaction_id is required."},
                    status_code=400,
                )
            signed = fetch_signed_transaction(transaction_id)
        transaction = verify_signed_transaction(signed)
        supabase = create_service_role_client()
        result = apply_apple_subscription(
            supabase,
            transaction,
            user_id=str(user["id"]),
            require_account_token=True,
        )
    except AppleIapConfigError as exc:
        logger.error("[apple verify] configuration: %s", exc)
        return _json_error(exc)
    except AppleVerificationError as exc:
        logger.info("[apple verify] rejected: %s", exc)
        return _json_error(exc)
    except Exception:
        logger.exception("[apple verify] failed")
        return JSONResponse({"error": "Could not verify the App Store transaction."}, status_code=500)

    response = _result_response(result)
    if isinstance(response, JSONResponse):
        return response
    return response


@router.post("/api/apple/notifications")
async def apple_server_notifications(request: Request):
    """App Store Server Notifications V2. The body is a signed JWS, not a shared secret."""
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)

    try:
        notification = verify_signed_notification(body.get("signedPayload") or "")
        if str(notification.get("notification_type") or "").upper() == "TEST":
            return {"ok": True, "ignored": True, "reason": "test_notification"}

        transaction = None
        signed_transaction = notification.get("signed_transaction_info")
        if signed_transaction:
            transaction = verify_signed_transaction(signed_transaction)

        auto_renew_status = None
        signed_renewal = notification.get("signed_renewal_info")
        if signed_renewal:
            renewal = verify_signed_renewal(signed_renewal)
            auto_renew_status = renewal.get("auto_renew_status")

        supabase = create_service_role_client()
        result = apply_apple_subscription(
            supabase,
            transaction,
            notification_type=notification.get("notification_type"),
            subtype=notification.get("subtype"),
            apple_status=notification.get("apple_status"),
            auto_renew_status=auto_renew_status,
            notification_uuid=notification.get("notification_uuid"),
            notification_signed_date_ms=notification.get("signed_date_ms"),
            require_account_token=False,
        )
    except AppleIapConfigError as exc:
        logger.error("[apple notifications] configuration: %s", exc)
        return _json_error(exc)
    except AppleVerificationError as exc:
        logger.info("[apple notifications] rejected: %s", exc)
        return _json_error(exc)
    except Exception:
        logger.exception("[apple notifications] failed")
        return JSONResponse({"error": "Could not process the App Store notification."}, status_code=500)

    response = _result_response(result)
    if isinstance(response, JSONResponse):
        return response
    return response
