"""Communication setup: voice/SMS/WhatsApp status + onboarding guidance for the mobile app."""

from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from api.auth import get_user_from_request
from communication.ensure import (
    ensure_business_communication,
    resolve_business_for_communication,
    resolve_target_business_for_new_receptionist,
)
from communication.setup_summary import build_setup_summary
from communication.sms_onboarding import activate_sms, merge_registration_profile, retry_sms, submit_sms_registration
from communication.whatsapp_onboarding import connect_whatsapp, continue_whatsapp_setup, retry_whatsapp

router = APIRouter()


def _require_auth(request: Request):
    user, supabase = get_user_from_request(request)
    if not user or not supabase:
        return None, None
    return user, supabase


def _query_business_id(request: Request) -> str | None:
    q = (request.query_params.get("business_id") or "").strip()
    return q or None


def _resolve_business(request: Request, supabase, user_id: str):
    return resolve_business_for_communication(supabase, user_id, _query_business_id(request))


@router.get("/communication/setup")
async def get_communication_setup(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    biz, is_default = _resolve_business(request, supabase, user["id"])
    if not biz:
        try:
            biz = resolve_target_business_for_new_receptionist(supabase, user["id"], None)
            ensure_business_communication(supabase, str(biz["id"]))
            biz, is_default = _resolve_business(request, supabase, user["id"])
        except Exception:
            return JSONResponse(
                {"error": "No business record yet. Complete assistant setup first."},
                status_code=404,
            )

    bid = biz["id"]
    phone = (
        supabase.table("business_phone_numbers").select("*").eq("business_id", bid).limit(1).execute().data
        or []
    )
    sms = (
        supabase.table("sms_campaigns").select("*").eq("business_id", bid).limit(1).execute().data or []
    )
    wa = (
        supabase.table("whatsapp_accounts").select("*").eq("business_id", bid).limit(1).execute().data or []
    )

    primary_name = None
    prid = biz.get("primary_receptionist_id")
    if prid:
        r = supabase.table("receptionists").select("name").eq("id", prid).limit(1).execute()
        if r.data:
            primary_name = (r.data[0].get("name") or "").strip() or None

    summary = build_setup_summary(
        biz,
        phone[0] if phone else None,
        sms[0] if sms else None,
        wa[0] if wa else None,
        is_default_business=is_default,
        primary_receptionist_name=primary_name,
    )
    return summary


@router.post("/communication/sms/activate")
async def post_activate_sms(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    biz, _ = _resolve_business(request, supabase, user["id"])
    if not biz:
        return JSONResponse({"error": "No business record"}, status_code=404)

    ok, err, st = activate_sms(supabase, biz["id"])
    if not ok:
        return JSONResponse({"error": err or "Failed"}, status_code=400)
    return {"success": True, "status": st}


@router.patch("/communication/sms/registration")
async def patch_sms_registration(request: Request):
    """Merge fields into sms_campaigns.registration_profile (PII/compliance)."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    biz, _ = _resolve_business(request, supabase, user["id"])
    if not biz:
        return JSONResponse({"error": "No business record"}, status_code=404)

    try:
        body = await request.json()
    except Exception:
        body = {}
    patch = body.get("registration") if isinstance(body.get("registration"), dict) else body
    if not isinstance(patch, dict):
        return JSONResponse({"error": "Expected JSON object or { \"registration\": { ... } }"}, status_code=400)

    ok, err = merge_registration_profile(supabase, biz["id"], patch)
    if not ok:
        return JSONResponse({"error": err or "Failed"}, status_code=400)
    return {"success": True}


@router.post("/communication/sms/submit")
async def post_submit_sms(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    biz, _ = _resolve_business(request, supabase, user["id"])
    if not biz:
        return JSONResponse({"error": "No business record"}, status_code=404)

    try:
        body = await request.json()
    except Exception:
        body = {}
    profile_patch = None
    if isinstance(body, dict):
        if isinstance(body.get("registration"), dict):
            profile_patch = body["registration"]
        elif isinstance(body.get("profile_patch"), dict):
            profile_patch = body["profile_patch"]

    ok, err, st = submit_sms_registration(supabase, biz["id"], profile_patch=profile_patch)
    if not ok:
        return JSONResponse({"error": err or "Failed"}, status_code=400)
    return {"success": True, "status": st}


@router.post("/communication/sms/retry")
async def post_retry_sms(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    biz, _ = _resolve_business(request, supabase, user["id"])
    if not biz:
        return JSONResponse({"error": "No business record"}, status_code=404)

    ok, err, st = retry_sms(supabase, biz["id"])
    if not ok:
        return JSONResponse({"error": err or "Failed"}, status_code=400)
    return {"success": True, "status": st}


@router.post("/communication/whatsapp/connect")
async def post_connect_whatsapp(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    biz, _ = _resolve_business(request, supabase, user["id"])
    if not biz:
        return JSONResponse({"error": "No business record"}, status_code=404)

    ok, err, payload = connect_whatsapp(supabase, biz["id"])
    if not ok:
        return JSONResponse({"error": err}, status_code=400)
    return {"success": True, **(payload or {})}


@router.post("/communication/whatsapp/continue")
async def post_continue_whatsapp(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    biz, _ = _resolve_business(request, supabase, user["id"])
    if not biz:
        return JSONResponse({"error": "No business record"}, status_code=404)

    ok, err, payload = continue_whatsapp_setup(supabase, biz["id"])
    if not ok:
        return JSONResponse({"error": err}, status_code=400)
    return {"success": True, **(payload or {})}


@router.post("/communication/whatsapp/retry")
async def post_retry_whatsapp(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    biz, _ = _resolve_business(request, supabase, user["id"])
    if not biz:
        return JSONResponse({"error": "No business record"}, status_code=404)

    ok, err, payload = retry_whatsapp(supabase, biz["id"])
    if not ok:
        return JSONResponse({"error": err}, status_code=400)
    return {"success": True, **(payload or {})}
