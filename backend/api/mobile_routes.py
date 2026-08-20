"""Mobile API routes: auth, push, Stripe, receptionists, settings."""

from __future__ import annotations

import hmac
import hashlib
import logging
import re
import time
from datetime import datetime
from typing import Any

import httpx
import stripe
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, RedirectResponse, Response

from api.auth import get_user_from_request
from voice_presets import (
    DEFAULT_PRESET_KEY,
    PRESET_KEYS,
    PREVIEW_SAMPLE_TEXT,
    get_preset,
    infer_preset_key_from_voice_id,
    list_presets_for_api,
    resolve_voice_id,
    resolve_tts_voice,
)
from voice.tts_facade import google_preview_mp3
from config import settings
from google_oauth_scopes import SCOPES
from prompts.fetch import _build_from_supabase_sync
from quota import check_outbound_quota
from billing.stripe_sync import (
    stripe_subscription_status_to_db_status,
    upsert_subscription_from_stripe,
)
from billing.subscriptions import get_billing_access_state
from stripe_plans import get_price_id_for_plan_id, plan_from_subscription
from billing.launch_trial import maybe_activate_launch_trial
from supabase_client import create_service_role_client
from telnyx import provision as telnyx_provision
from telnyx.recording_download import fetch_fresh_recording_mp3_url
from communication.ensure import (
    ensure_business_communication,
    ensure_communication_for_user_after_receptionist_change,
    get_default_business_for_owner,
    list_active_receptionists_for_business,
    mark_business_phone_line_failed,
    refresh_business_after_primary_receptionist_removed,
    resolve_target_business_for_new_receptionist,
    upsert_canonical_business_phone,
)

from api.mobile.agenda import router as agenda_router
from api.mobile.dashboard import router as dashboard_router
from api.mobile.call_logs_projection import (
    fetch_call_log_by_id_with_fallback,
    fetch_call_logs_with_fallback,
    is_missing_column_error,
)
from api.mobile.settings import router as settings_router
from api.mobile.communication import router as communication_router
from api.mobile.businesses import router as businesses_router
from api.mobile.number_transfers import router as number_transfers_router
from api.mobile.voice_clones import assert_owned_clone, router as voice_clones_router

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/mobile", tags=["mobile"])


def _has_recording_ai_consent(body: dict[str, Any]) -> bool:
    """Require explicit owner consent acknowledgement before creating a receptionist."""
    value = body.get("consent")
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"true", "1", "yes", "y", "on"}
    return False


def _stripe_metadata_to_dict(metadata) -> dict:
    if not metadata:
        return {}
    if isinstance(metadata, dict):
        return metadata
    try:
        return dict(metadata)
    except Exception:
        to_dict = getattr(metadata, "to_dict", None)
        if callable(to_dict):
            try:
                return to_dict()
            except Exception:
                return {}
    return {}


def _sync_user_plan_from_billing_plan(supabase, user_id: str, plan: dict) -> None:
    meta = plan.get("billing_plan_metadata") or {}
    included = int(meta.get("included_minutes") or 0)
    overage_cents = int(meta.get("overage_rate_cents") or 20)
    try:
        existing = (
            supabase.table("user_plans")
            .select("inbound_percent, outbound_percent")
            .eq("user_id", user_id)
            .limit(1)
            .execute()
        )
        inbound_pct = 80
        outbound_pct = 20
        if existing.data and len(existing.data) > 0:
            inbound_pct = existing.data[0].get("inbound_percent") or inbound_pct
            outbound_pct = existing.data[0].get("outbound_percent") or outbound_pct

        is_payg = plan.get("billing_plan") == "subscription_payg"
        alloc_in = int((included * inbound_pct) / 100) if not is_payg else None
        alloc_out = (included - alloc_in) if alloc_in is not None else None
        supabase.table("user_plans").upsert(
            {
                "user_id": user_id,
                "billing_plan": plan["billing_plan"],
                "allocated_inbound_minutes": alloc_in,
                "allocated_outbound_minutes": alloc_out,
                "inbound_percent": inbound_pct,
                "outbound_percent": outbound_pct,
                "overage_rate_cents": overage_cents,
                "payg_rate_cents": int(meta.get("payg_rate_cents") or 20),
                "updated_at": datetime.utcnow().isoformat() + "Z",
            },
            on_conflict="user_id",
        ).execute()
    except Exception as e:
        logger.warning("[sync-session] user_plans sync failed: %s", e)

# appointments: base columns (020, 023) vs optional from 030
APPOINTMENTS_BASE_SELECT = (
    "id, receptionist_id, event_id, start_time, end_time, duration_minutes, "
    "summary, description, service_id, service_name, location_type, location_text, "
    "customer_address, price_cents, notes, booking_mode, "
    "followup_mode, followup_message_resolved, payment_link, "
    "meeting_instructions, owner_selected_platform, internal_followup_notes, "
    "created_at, updated_at"
)
APPOINTMENTS_OPTIONAL_030 = "status, caller_number, call_log_id, confirmation_message_sent_at, payment_link_sent_at"
APPOINTMENTS_FULL_SELECT = f"{APPOINTMENTS_BASE_SELECT}, {APPOINTMENTS_OPTIONAL_030}"

router.include_router(dashboard_router)
router.include_router(settings_router)
router.include_router(communication_router)
router.include_router(businesses_router)
router.include_router(agenda_router)
router.include_router(number_transfers_router)
router.include_router(voice_clones_router)


def _require_auth(request: Request) -> tuple[dict | None, Any]:
    """Return (user, supabase). user is None if unauthorized."""
    user, supabase = get_user_from_request(request)
    if not user or not supabase:
        return (None, None)
    return (user, supabase)


def _ensure_user_profile(supabase, user: dict) -> dict:
    """Create or repair the public.users row for the authenticated Supabase user."""
    user_id = str(user.get("id") or "").strip()
    if not user_id:
        raise ValueError("Missing authenticated user id")

    email = (user.get("email") or "").strip() or None
    now = datetime.utcnow().isoformat() + "Z"

    existing = (
        supabase.table("users")
        .select("id, email, created_at, onboarding_completed_at, subscription_status, billing_plan")
        .eq("id", user_id)
        .limit(1)
        .execute()
    )
    if existing.data:
        row = existing.data[0]
        if email and row.get("email") != email:
            updated = (
                supabase.table("users")
                .update({"email": email, "updated_at": now})
                .eq("id", user_id)
                .execute()
            )
            if updated.data:
                row = updated.data[0]
            else:
                row = {**row, "email": email, "updated_at": now}
        row = maybe_activate_launch_trial(
            supabase,
            user_id,
            row,
            sync_user_plan=_sync_user_plan_from_billing_plan,
        )
        return {"created": False, "profile": row}

    insert_row = {
        "id": user_id,
        "email": email,
        "updated_at": now,
    }
    created = (
        supabase.table("users")
        .upsert(insert_row, on_conflict="id")
        .execute()
    )
    profile = created.data[0] if created.data else insert_row
    profile = maybe_activate_launch_trial(
        supabase,
        user_id,
        profile,
        sync_user_plan=_sync_user_plan_from_billing_plan,
    )
    return {"created": True, "profile": profile}


@router.post("/profile/ensure")
async def ensure_profile(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        result = _ensure_user_profile(supabase, user)
        profile = result["profile"] or {}
        return {
            "ok": True,
            "created": bool(result["created"]),
            "user": {
                "id": profile.get("id") or user["id"],
                "email": profile.get("email") or user.get("email"),
                "subscription_status": profile.get("subscription_status"),
                "billing_plan": profile.get("billing_plan"),
                "onboarding_completed_at": profile.get("onboarding_completed_at"),
            },
        }
    except Exception as e:
        logger.exception("[profile/ensure] %s", e)
        return JSONResponse({"ok": False, "error": str(e)}, status_code=500)


@router.get("/onboarding-status")
async def onboarding_status(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        profile_result = _ensure_user_profile(supabase, user)
        profile = profile_result["profile"] or {}
        profile_row = (
            supabase.table("users")
            .select(
                "id, email, calendar_id, phone, subscription_status, "
                "billing_plan, onboarding_completed_at, active_business_id"
            )
            .eq("id", user["id"])
            .limit(1)
            .execute()
        )
        if profile_row.data:
            profile = profile_row.data[0]

        business = None
        business_created = False
        try:
            had_business = get_default_business_for_owner(supabase, user["id"]) is not None
            business = resolve_target_business_for_new_receptionist(
                supabase,
                user["id"],
                None,
            )
            business_created = bool(not had_business and business)
        except Exception as e:
            logger.warning("[onboarding-status] business repair failed: %s", e)

        business_id = str(business["id"]) if business and business.get("id") else None
        phone_row = None
        if business_id:
            try:
                ensure_business_communication(supabase, business_id)
            except Exception as e:
                logger.warning("[onboarding-status] communication repair failed: %s", e)
            phone_res = (
                supabase.table("business_phone_numbers")
                .select("phone_number_e164, status, telnyx_number_id")
                .eq("business_id", business_id)
                .limit(1)
                .execute()
            )
            if phone_res.data:
                phone_row = phone_res.data[0]

        recs_res = (
            supabase.table("receptionists")
            .select("id, inbound_phone_number, phone_number, status, active, created_at")
            .eq("user_id", user["id"])
            .order("created_at")
            .limit(1)
            .execute()
        )
        rec = (recs_res.data or [None])[0]

        calendar_id = (profile.get("calendar_id") or "").strip() or None
        billing_state = get_billing_access_state(
            supabase,
            user["id"],
            profile=profile,
        )
        subscription_status = billing_state.get("status")
        business_phone = None
        phone_status = None
        if phone_row:
            business_phone = (phone_row.get("phone_number_e164") or "").strip() or None
            phone_status = (phone_row.get("status") or "").strip() or None
        receptionist_phone = None
        if rec:
            receptionist_phone = (
                (rec.get("inbound_phone_number") or "").strip()
                or (rec.get("phone_number") or "").strip()
                or None
            )
        phone = business_phone or receptionist_phone or ((profile.get("phone") or "").strip() or None)

        has_calendar = bool(calendar_id)
        has_active_subscription = bool(billing_state["has_active_subscription"])
        has_receptionist = bool(rec)
        has_business = bool(business_id)
        has_business_phone_number = bool(phone)

        if not has_calendar:
            current_step = "connect_calendar"
        elif not has_active_subscription:
            current_step = "subscribe"
        elif not has_receptionist:
            current_step = "create_receptionist"
        elif not has_business_phone_number:
            current_step = "test_call"
        else:
            current_step = "done"

        return {
            "hasProfile": True,
            "profileCreated": bool(profile_result["created"]),
            "hasActiveSubscription": has_active_subscription,
            "subscriptionStatus": subscription_status or None,
            "subscriptionSource": billing_state.get("source"),
            "billingPlan": profile.get("billing_plan"),
            "hasCalendar": has_calendar,
            "calendarId": calendar_id,
            "hasBusiness": has_business,
            "businessCreated": business_created,
            "businessId": business_id,
            "hasReceptionist": has_receptionist,
            "receptionistId": rec.get("id") if rec else None,
            "hasBusinessPhoneNumber": has_business_phone_number,
            "phoneNumber": phone,
            "phoneStatus": phone_status,
            "onboardingCompletedAt": profile.get("onboarding_completed_at"),
            "currentStep": current_step,
        }
    except Exception as e:
        logger.exception("[onboarding-status] %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)


def _compute_onboarding_completion_state(supabase, user: dict) -> dict[str, Any]:
    """Authoritative completion check before marking onboarding complete."""
    profile_result = _ensure_user_profile(supabase, user)
    profile = profile_result["profile"] or {}
    profile_row = (
        supabase.table("users")
        .select(
            "id, email, calendar_id, phone, subscription_status, "
            "billing_plan, onboarding_completed_at, active_business_id"
        )
        .eq("id", user["id"])
        .limit(1)
        .execute()
    )
    if profile_row.data:
        profile = profile_row.data[0]

    calendar_id = (profile.get("calendar_id") or "").strip()
    billing_state = get_billing_access_state(supabase, user["id"], profile=profile)

    try:
        business = resolve_target_business_for_new_receptionist(supabase, user["id"], None)
        business_id = str(business["id"]) if business and business.get("id") else None
    except Exception:
        business_id = None

    phone = None
    if business_id:
        try:
            ensure_business_communication(supabase, business_id)
        except Exception as e:
            logger.warning("[onboarding/complete] communication repair failed: %s", e)
        phone_res = (
            supabase.table("business_phone_numbers")
            .select("phone_number_e164, status, telnyx_number_id")
            .eq("business_id", business_id)
            .limit(1)
            .execute()
        )
        phone_row = (phone_res.data or [None])[0]
        if phone_row:
            phone = (phone_row.get("phone_number_e164") or "").strip() or None

    recs_res = (
        supabase.table("receptionists")
        .select("id")
        .eq("user_id", user["id"])
        .eq("status", "active")
        .eq("active", True)
        .is_("deleted_at", "null")
        .limit(1)
        .execute()
    )
    receptionist_id = (recs_res.data or [{}])[0].get("id") if recs_res.data else None

    missing: list[str] = []
    if not calendar_id:
        missing.append("calendar")
    if not billing_state["has_active_subscription"]:
        missing.append("subscription")
    if not receptionist_id:
        missing.append("receptionist")
    if not phone:
        missing.append("business_phone_number")

    return {
        "ready": not missing,
        "missing": missing,
        "calendarId": calendar_id or None,
        "hasActiveSubscription": bool(billing_state["has_active_subscription"]),
        "subscriptionStatus": billing_state.get("status"),
        "businessId": business_id,
        "receptionistId": receptionist_id,
        "phoneNumber": phone,
    }


@router.post("/onboarding/complete")
async def complete_onboarding(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        state = _compute_onboarding_completion_state(supabase, user)
        if not state["ready"]:
            return JSONResponse(
                {
                    "completed": False,
                    "error": "Onboarding is not complete yet.",
                    "missing": state["missing"],
                },
                status_code=400,
            )

        now = datetime.utcnow().isoformat() + "Z"
        supabase.table("users").update(
            {
                "onboarding_completed_at": now,
                "updated_at": now,
            }
        ).eq("id", user["id"]).is_("onboarding_completed_at", "null").execute()
        return {"completed": True, **state}
    except Exception as e:
        logger.exception("[onboarding/complete] %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)


# --- Push token ---
@router.post("/push-token")
async def push_token(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    token = (body.get("token") or "").strip()
    if not token:
        return JSONResponse({"error": "token required"}, status_code=400)

    try:
        supabase.table("user_push_tokens").upsert(
            {"user_id": user["id"], "token": token, "updated_at": datetime.utcnow().isoformat() + "Z"},
            on_conflict="user_id",
        ).execute()
        return {"success": True}
    except Exception as e:
        logger.exception("[push-token] %s", e)
        return JSONResponse({"error": "Failed to register token"}, status_code=500)


# --- Voice presets (receptionist voice selection) ---
@router.get("/voice-presets")
async def list_voice_presets(request: Request):
    """Return curated voice presets for receptionist creation/settings. No raw voice_id exposed."""
    user, _ = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    return {"presets": list_presets_for_api()}


@router.get("/voice-presets/{key}/preview")
async def voice_preset_preview(request: Request, key: str):
    """Return short preview audio for a voice preset. Requires auth. Lightweight on-demand generation."""
    user, _ = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    preset = get_preset(key)
    if not preset:
        return JSONResponse({"error": "Preset not found"}, status_code=404)
    try:
        rv = resolve_tts_voice(key, None)
        audio_bytes = await google_preview_mp3(PREVIEW_SAMPLE_TEXT, rv)
        return Response(content=audio_bytes, media_type="audio/mpeg")
    except Exception as e:
        logger.warning("[voice-presets/preview] %s: %s", key, e)
        return JSONResponse({"error": "Preview failed"}, status_code=502)


# --- Sync session (Stripe Checkout session_id) ---
@router.post("/sync-session")
async def sync_session(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    session_id = (body.get("session_id") or "").strip()
    if not session_id:
        return JSONResponse({"error": "session_id required"}, status_code=400)

    result = await _sync_subscription_from_session(session_id, user["id"])
    if result.get("error"):
        return JSONResponse({"synced": False, "error": result["error"]}, status_code=400)
    return {"synced": result.get("synced", True)}


async def _sync_subscription_from_session(session_id: str, user_id: str) -> dict:
    """Sync subscription from Stripe Checkout session."""
    sk = (settings.stripe_secret_key or "").strip()
    if not sk:
        return {"synced": False, "error": "Stripe not configured"}
    stripe.api_key = sk
    try:
        session = stripe.checkout.Session.retrieve(session_id, expand=["subscription"])
        if session.payment_status != "paid" and session.status != "complete":
            return {"synced": False}
        customer_id = session.customer if isinstance(session.customer, str) else (session.customer.id if session.customer else None)
        metadata = _stripe_metadata_to_dict(getattr(session, "metadata", None))
        meta_user_id = metadata.get("userId") or session.client_reference_id
        if not meta_user_id or str(meta_user_id) != str(user_id):
            return {"synced": False}
        updates = {
            "id": user_id,
            "stripe_customer_id": customer_id,
            "subscription_status": "past_due",
            "updated_at": datetime.utcnow().isoformat() + "Z",
        }
        sub_id = session.subscription
        sub_obj = None
        plan = None
        if sub_id:
            sub_obj = sub_id if hasattr(sub_id, "id") else stripe.Subscription.retrieve(sub_id, expand=["items.data.price"])
            updates["stripe_subscription_id"] = sub_obj.id if hasattr(sub_obj, "id") else str(sub_id)
            updates["subscription_status"] = stripe_subscription_status_to_db_status(
                getattr(sub_obj, "status", None)
            )
            plan = plan_from_subscription(sub_obj)
            if plan:
                updates["billing_plan"] = plan["billing_plan"]
                updates["billing_plan_metadata"] = plan.get("billing_plan_metadata")
        supabase = create_service_role_client()
        if sub_id and plan:
            upsert_subscription_from_stripe(
                supabase, user_id=user_id, stripe_subscription=sub_obj, plan=plan
            )
            _sync_user_plan_from_billing_plan(supabase, user_id, plan)
        supabase.table("users").upsert(updates, on_conflict="id").execute()
        return {"synced": True}
    except Exception as e:
        logger.exception("[sync-session] %s", e)
        return {"synced": False, "error": str(e)}


# --- Google Auth URL ---
@router.get("/google-auth-url")
async def google_auth_url(request: Request):
    user, _ = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    return_to = request.query_params.get("return_to", "dashboard")
    try:
        from google_auth_oauthlib.flow import Flow
        redirect_uri = settings.get_google_redirect_uri()
        flow = Flow.from_client_config(
            {
                "web": {
                    "client_id": settings.google_client_id,
                    "client_secret": settings.google_client_secret,
                    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                    "token_uri": "https://oauth2.googleapis.com/token",
                    "redirect_uris": [redirect_uri],
                }
            },
            scopes=SCOPES,
            redirect_uri=redirect_uri,
            # IMPORTANT: We want pure server-side OAuth for this flow (no PKCE).
            # PKCE requires persisting the code_verifier across request/callback, which we do not do.
            autogenerate_code_verifier=False,
        )
        # Sign state so callback cannot be tricked into associating tokens with wrong user (CSRF).
        timestamp = int(time.time())
        payload = f"{user['id']}:{return_to}:{timestamp}"
        secret = (settings.google_oauth_state_secret or settings.supabase_service_role_key or "").encode("utf-8")
        if not secret:
            logger.error("[google-auth-url] Google OAuth state secret not configured (set GOOGLE_OAUTH_STATE_SECRET or SUPABASE_SERVICE_ROLE_KEY)")
            return JSONResponse({"error": "Server configuration error"}, status_code=500)
        signature = hmac.new(secret, payload.encode("utf-8"), hashlib.sha256).hexdigest()
        state = f"{payload}.{signature}"
        url, _ = flow.authorization_url(
            access_type="offline",
            prompt="consent",
            state=state,
        )
        # Debug: confirm redirect URI and whether PKCE is enabled (it should NOT be)
        pkce_enabled = bool(getattr(flow, "code_verifier", None))
        logger.info(
            "[google-auth-url] redirect_uri=%r pkce_enabled=%s return_to=%s scopes=%s",
            redirect_uri,
            pkce_enabled,
            return_to,
            " ".join(SCOPES),
        )
        return {"url": url}
    except Exception as e:
        logger.exception("[google-auth-url] %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)


# --- Checkout ---
@router.post("/checkout")
async def checkout(request: Request):
    user, _ = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    if not user.get("email"):
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    plan_id = body.get("plan_id", "starter")
    # Public: starter, growth, business. Internal: dev_test (API/deep-link only).
    allowed_checkout_plan_ids = {"starter", "growth", "business", "dev_test"}
    if plan_id not in allowed_checkout_plan_ids:
        return JSONResponse(
            {"error": "Invalid plan. Choose starter, growth, or business."},
            status_code=400,
        )
    return_scheme = body.get("return_scheme") or settings.mobile_redirect_scheme

    price_id = get_price_id_for_plan_id(plan_id)
    if not price_id:
        return JSONResponse(
            {"error": f"Stripe price for {plan_id} is not configured."},
            status_code=400,
        )

    sk = (settings.stripe_secret_key or "").strip()
    if not sk:
        return JSONResponse({"error": "Stripe not configured"}, status_code=503)
    stripe.api_key = sk

    app_url = settings.get_app_url()
    success_url = f"{return_scheme}://checkout?session_id={{CHECKOUT_SESSION_ID}}" if return_scheme == "echodesk" else f"{app_url}/dashboard?session_id={{CHECKOUT_SESSION_ID}}"
    cancel_url = f"{return_scheme}://checkout?cancelled=1" if return_scheme == "echodesk" else f"{app_url}/dashboard"

    try:
        session = stripe.checkout.Session.create(
            mode="subscription",
            payment_method_types=["card"],
            line_items=[{"price": price_id, "quantity": 1}],
            success_url=success_url,
            cancel_url=cancel_url,
            customer_email=user["email"],
            metadata={"userId": user["id"], "email": user["email"]},
            subscription_data={"metadata": {"userId": user["id"], "email": user["email"]}},
        )
        if not session.url:
            return JSONResponse({"error": "Could not create checkout session."}, status_code=500)
        return {"url": session.url}
    except Exception as e:
        logger.exception("[checkout] %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)


# --- Billing portal ---
@router.post("/billing-portal")
async def billing_portal(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except Exception:
        body = {}
    return_scheme = body.get("return_scheme") or settings.mobile_redirect_scheme

    row = supabase.table("users").select("stripe_customer_id").eq("id", user["id"]).single().execute()
    profile = (row.data or {}) if row.data else {}
    customer_id = profile.get("stripe_customer_id")
    if not customer_id:
        return JSONResponse({"error": "No billing account. Complete a subscription first."}, status_code=400)

    sk = (settings.stripe_secret_key or "").strip()
    if not sk:
        return JSONResponse({"error": "Stripe not configured"}, status_code=503)
    stripe.api_key = sk

    app_url = settings.get_app_url()
    return_url = f"{return_scheme}://settings" if return_scheme == "echodesk" else f"{app_url}/settings"

    try:
        portal_kwargs = {
            "customer": customer_id,
            "return_url": return_url,
        }
        portal_config = (settings.stripe_billing_portal_configuration_id or "").strip()
        if portal_config:
            portal_kwargs["configuration"] = portal_config
        session = stripe.billing_portal.Session.create(
            **portal_kwargs,
        )
        return {"url": session.url}
    except Exception as e:
        logger.exception("[billing-portal] %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)


# --- Receptionists ---
def _assert_receptionist_ownership(receptionist_id: str, user_id: str, supabase) -> str | None:
    """Return None if ok, else error string."""
    try:
        r = (
            supabase.table("receptionists")
            .select("id, user_id")
            .eq("id", receptionist_id)
            .limit(1)
            .execute()
        )
    except Exception as e:
        logger.warning("[CALL_DIAG] receptionist ownership lookup failed receptionist_id=%s: %s", receptionist_id, e)
        return "Receptionist not found"
    rows = r.data if r and isinstance(r.data, list) else []
    if not rows:
        return "Receptionist not found"
    if (rows[0] or {}).get("user_id") != user_id:
        return "Receptionist not found"
    return None


@router.post("/receptionists/create")
async def create_receptionist(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    profile = supabase.table("users").select("subscription_status, calendar_refresh_token").eq("id", user["id"]).single().execute()
    p = (profile.data or {}) if profile.data else {}
    billing_state = get_billing_access_state(supabase, user["id"], profile=p)
    if not billing_state["has_active_subscription"]:
        return JSONResponse({"error": "Active subscription required."}, status_code=400)
    if not p.get("calendar_refresh_token"):
        return JSONResponse({"error": "Please connect Google Calendar first. Go to Settings → Integrations."}, status_code=400)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)

    if not _has_recording_ai_consent(body):
        return JSONResponse(
            {
                "error": (
                    "Consent confirmation is required before creating a receptionist."
                )
            },
            status_code=400,
        )

    webhook_base = (settings.telnyx_webhook_base_url or settings.get_app_url()).strip().rstrip("/")
    if not webhook_base or "localhost" in webhook_base or "placeholder" in webhook_base.lower():
        return JSONResponse({"error": "TELNYX_WEBHOOK_BASE_URL must be set before provisioning."}, status_code=400)

    body_business_id = (body.get("business_id") or "").strip() or None
    try:
        target_business = resolve_target_business_for_new_receptionist(
            supabase, user["id"], body_business_id
        )
    except ValueError:
        return JSONResponse({"error": "Invalid business."}, status_code=400)
    except RuntimeError:
        return JSONResponse({"error": "Could not create business record."}, status_code=500)

    target_business_id = str(target_business["id"])
    existing_for_business = list_active_receptionists_for_business(supabase, target_business_id)
    if existing_for_business:
        return JSONResponse(
            {
                "error": (
                    "This business already has an assistant. "
                    "Open Settings to switch Solo/Business, then add staff or store "
                    "locations — each can use its own Google calendar under your "
                    "connected account. Creating another assistant is not needed."
                )
            },
            status_code=400,
        )

    # Wizard or legacy — only one assistant per business may provision a Telnyx number.
    phone_strategy = body.get("phone_strategy")
    if phone_strategy == "own":
        return JSONResponse(
            {
                "error": (
                    "Linking an existing number instantly is no longer available. "
                    "Get a new business number to continue, or submit a transfer request from the phone step."
                )
            },
            status_code=400,
        )

    name = (body.get("name") or "").strip()
    calendar_id = (body.get("calendar_id") or "").strip()
    if not name:
        return JSONResponse({"error": "Name is required."}, status_code=400)
    if not calendar_id:
        return JSONResponse({"error": "Calendar ID is required."}, status_code=400)

    staff_list = body.get("staff") or []
    service_list = body.get("services") or []
    extra_instructions = (body.get("extra_instructions") or "").strip() or None
    system_prompt = (body.get("system_prompt") or "").strip() or None
    greeting = (body.get("greeting") or "").strip() or None
    raw_voice_id = (body.get("voice_id") or "").strip() or None  # legacy/admin only
    voice_preset_key = (body.get("voice_preset_key") or "").strip() or None
    voice_clone_id = (body.get("voice_clone_id") or "").strip() or None
    if voice_clone_id:
        clone_err = assert_owned_clone(supabase, user["id"], voice_clone_id)
        if clone_err:
            return JSONResponse({"error": clone_err}, status_code=400)

    # Validate/coerce preset key:
    # - valid key -> use it
    # - invalid key -> default preset (avoid silent/surprising behavior)
    # - missing key -> legacy path (keep raw voice_id if provided)
    if voice_preset_key and voice_preset_key not in PRESET_KEYS:
        voice_preset_key = DEFAULT_PRESET_KEY

    voice_id = resolve_voice_id(voice_preset_key, raw_voice_id)
    if not voice_id:
        return JSONResponse({"error": "Voice configuration missing"}, status_code=400)

    from scheduling.bookable_hours import normalize_bookable_hours

    bookable_hours = normalize_bookable_hours(body.get("bookable_hours"))
    if not bookable_hours:
        return JSONResponse(
            {
                "error": (
                    "Bookable hours are required. Set open/closed and a 24-hour start–end "
                    "time for each day of the week (at least one open day)."
                )
            },
            status_code=400,
        )

    # Ensure mobile-created records always store a preset key.
    # But if caller supplied a raw voice_id (admin/legacy), don't stamp a potentially-wrong preset label.
    if not voice_preset_key and not raw_voice_id:
        voice_preset_key = DEFAULT_PRESET_KEY
    assistant_identity = (body.get("assistant_identity") or "").strip() or None
    promotions = (body.get("promotions") or body.get("promos") or "").strip()
    mode = (body.get("mode") or "personal").strip().lower()
    if mode not in ("personal", "business"):
        mode = "personal"

    telnyx_id: str | None = None
    inbound_number: str | None = None
    telnyx_phone: str | None = None

    area_code = body.get("area_code") or "212"
    if area_code == "other":
        area_code = "212"

    # One DID per account, with an optional extra while the old line is held.
    # Default: reuse the business line. Buying another is allowed only when
    # there is exactly one held DID and no live receptionist (1 live + 1 held).
    use_held_number = body.get("use_held_number")
    want_keep = True if use_held_number is None else bool(use_held_number)

    existing_line = (
        supabase.table("business_phone_numbers")
        .select("phone_number_e164, telnyx_number_id, status")
        .eq("business_id", target_business_id)
        .limit(1)
        .execute()
    )
    line_row = (existing_line.data or [None])[0]
    existing_e164 = ""
    existing_tid = ""
    if line_row:
        existing_e164 = (line_row.get("phone_number_e164") or "").strip()
        existing_tid = (line_row.get("telnyx_number_id") or "").strip()

    reclaimed_from_id: str | None = None
    if existing_e164 and existing_tid and want_keep:
        telnyx_id = existing_tid
        telnyx_phone = existing_e164
        inbound_number = existing_e164
        logger.info(
            "[receptionists/create] reusing business line e164=%s id=%s",
            existing_e164,
            existing_tid,
        )
    elif existing_e164 and existing_tid and not want_keep:
        from telnyx.phone_lifecycle import (
            can_purchase_extra_number,
            collect_account_phone_inventory,
            park_did_on_latest_deleted,
        )

        inventory = collect_account_phone_inventory(supabase, user["id"])
        if not can_purchase_extra_number(inventory):
            return JSONResponse(
                {
                    "error": (
                        "You already have a business number. Keep it, or wait until "
                        "the unused held number is released (about 48 hours)."
                    )
                },
                status_code=400,
            )
        parked = park_did_on_latest_deleted(
            supabase,
            target_business_id,
            e164=existing_e164,
            telnyx_id=existing_tid,
        )
        logger.info(
            "[receptionists/create] buying extra DID; parked previous e164=%s parked=%s",
            existing_e164,
            parked,
        )
        # Fall through to acquire a new number.

    if not telnyx_id or not inbound_number:
        from telnyx.phone_lifecycle import (
            detach_phone_from_receptionist,
            find_reclaimable_number_for_business,
        )

        if want_keep:
            reclaim = find_reclaimable_number_for_business(supabase, target_business_id)
            if reclaim:
                telnyx_id = reclaim["telnyx_id"]
                telnyx_phone = reclaim["e164"]
                inbound_number = reclaim["e164"]
                reclaimed_from_id = reclaim.get("receptionist_id") or None
                logger.info(
                    "[receptionists/create] reclaiming leftover DID e164=%s id=%s from=%s",
                    inbound_number,
                    telnyx_id,
                    reclaimed_from_id,
                )
                try:
                    telnyx_provision.configure_voice_url(
                        telnyx_id, f"{webhook_base}/api/telnyx/voice"
                    )
                except Exception as cfg_ex:
                    logger.warning(
                        "[receptionists/create] configure reclaimed line failed id=%s: %s",
                        telnyx_id,
                        cfg_ex,
                    )
                if reclaimed_from_id:
                    try:
                        detach_phone_from_receptionist(supabase, reclaimed_from_id)
                    except Exception as det_ex:
                        logger.warning(
                            "[receptionists/create] detach after reclaim failed from=%s: %s",
                            reclaimed_from_id,
                            det_ex,
                        )

    if not telnyx_id or not inbound_number:
        allow_orphan_reuse = True
        used_ids: set[str] = set()
        used_e164: set[str] = set()
        try:
            used_ids, used_e164 = telnyx_provision.collect_db_assigned_numbers(
                supabase
            )
            logger.info(
                "[receptionists/create] assigned inventory ids=%s e164=%s",
                len(used_ids),
                len(used_e164),
            )
        except Exception as scan_ex:
            # Fail closed: never reuse orphans without a complete inventory.
            allow_orphan_reuse = False
            logger.warning(
                "[receptionists/create] used-number scan failed; buying new only: %s",
                scan_ex,
            )

        try:
            tid, tphone, purchased_new = telnyx_provision.acquire_phone_number(
                area_code,
                used_ids=used_ids,
                used_e164=used_e164,
                allow_orphan_reuse=allow_orphan_reuse,
            )
            telnyx_id = tid
            telnyx_phone = tphone
            inbound_number = tphone
            logger.info(
                "[receptionists/create] acquired number e164=%s id=%s purchased_new=%s",
                tphone,
                tid,
                purchased_new,
            )
            try:
                telnyx_provision.configure_voice_url(
                    telnyx_id, f"{webhook_base}/api/telnyx/voice"
                )
            except Exception as cfg_ex:
                # Number is already owned; do not fail the whole create on webhook attach.
                logger.warning(
                    "[receptionists/create] configure_voice_url failed id=%s: %s",
                    telnyx_id,
                    cfg_ex,
                )
        except Exception as ex:
            try:
                mark_business_phone_line_failed(supabase, target_business_id)
            except Exception:
                pass
            return JSONResponse({"error": str(ex)}, status_code=400)
    else:
        # Reused business line — still ensure voice webhook/connection.
        try:
            telnyx_provision.configure_voice_url(
                telnyx_id, f"{webhook_base}/api/telnyx/voice"
            )
        except Exception as cfg_ex:
            logger.warning(
                "[receptionists/create] configure reused line failed id=%s: %s",
                telnyx_id,
                cfg_ex,
            )

    # Canonical line on the business; receptionist row below mirrors these for Telnyx voice routing.
    upsert_canonical_business_phone(
        supabase,
        target_business_id,
        phone_number_e164=inbound_number or telnyx_phone,
        telnyx_number_id=telnyx_id,
    )

    insert_data = {
        "user_id": user["id"],
        "business_id": target_business_id,
        "name": name,
        # Compatibility mirror only — source of truth is business_phone_numbers (see upsert_canonical_business_phone).
        "phone_number": inbound_number,
        "inbound_phone_number": inbound_number,
        "telnyx_phone_number_id": telnyx_id,
        "telnyx_phone_number": telnyx_phone or inbound_number,
        "calendar_id": calendar_id,
        "status": "active",
        "mode": mode,
        "extra_instructions": extra_instructions,
        "system_prompt": system_prompt,
        "greeting": greeting,
        "voice_id": voice_id,
        "voice_preset_key": voice_preset_key,
        "voice_clone_id": voice_clone_id,
        "assistant_identity": assistant_identity,
        "bookable_hours": bookable_hours,
    }
    try:
        logger.info("[receptionists/create] receptionist insert starting for user_id=%s name=%s", user["id"], name)
        # Supabase Python sync client does not support .insert(...).select(...); insert then get id from response or follow-up query
        insert_resp = supabase.table("receptionists").insert(insert_data).execute()
        rec_id = None
        if insert_resp.data and len(insert_resp.data) > 0:
            rec_id = insert_resp.data[0].get("id") if isinstance(insert_resp.data[0], dict) else getattr(insert_resp.data[0], "id", None)
        if not rec_id:
            # Fallback: fetch by unique fields for this request
            fetch = (
                supabase.table("receptionists")
                .select("id")
                .eq("user_id", user["id"])
                .eq("name", name)
                .eq("calendar_id", calendar_id)
                .eq("inbound_phone_number", inbound_number)
                .order("created_at", desc=True)
                .limit(1)
                .execute()
            )
            if fetch.data and len(fetch.data) > 0:
                rec_id = fetch.data[0].get("id") if isinstance(fetch.data[0], dict) else getattr(fetch.data[0], "id", None)
        logger.info(
            "[receptionists/create] insert response type=%s has_data=%s rec_id=%s",
            type(insert_resp).__name__,
            bool(insert_resp.data),
            rec_id,
        )
        if not rec_id:
            # Do not release a purchased Telnyx number here — retry will reuse the
            # business line / orphan instead of buying another DID.
            logger.warning(
                "[receptionists/create] failed to resolve rec_id after insert "
                "(kept telnyx_id=%s e164=%s for retry)",
                telnyx_id,
                inbound_number,
            )
            return JSONResponse({"error": "Failed to create receptionist"}, status_code=500)

        logger.info(
            "[receptionists/create] voice resolved rec_id=%s preset_key=%s voice_id=%s",
            rec_id,
            voice_preset_key,
            voice_id,
        )

        staff_done = False
        for s in staff_list:
            sn = (s.get("name") or "").strip()
            if sn:
                supabase.table("staff").insert({
                    "receptionist_id": rec_id,
                    "name": sn,
                    "role": (s.get("description") or "").strip() or None,
                    "is_active": True,
                }).execute()
                staff_done = True
        services_done = False
        for svc in service_list:
            nm = (svc.get("name") or "").strip()
            if not nm:
                continue
            desc = (svc.get("description") or "").strip() or None
            dur = svc.get("duration_minutes")
            price_cents = svc.get("price_cents")
            requires_location = bool(svc.get("requires_location"))
            default_location_type = (svc.get("default_location_type") or "").strip() or None
            try:
                dur_val = int(dur) if dur is not None else 0
            except (TypeError, ValueError):
                dur_val = 0
            try:
                price_val = int(price_cents) if price_cents is not None else 0
            except (TypeError, ValueError):
                price_val = 0
            row = {
                "receptionist_id": rec_id,
                "name": nm,
                "description": desc,
                "duration_minutes": dur_val,
                "price_cents": price_val,
                "requires_location": requires_location,
                "default_location_type": default_location_type,
            }
            supabase.table("services").insert(row).execute()
            services_done = True
        promos_done = False
        if promotions:
            supabase.table("promos").insert({"receptionist_id": rec_id, "description": promotions, "code": "WIZARD"}).execute()
            promos_done = True

        try:
            ensure_business_communication(supabase, target_business_id)
        except Exception as comm_ex:
            logger.warning("[receptionists/create] communication ensure failed: %s", comm_ex)

        try:
            now_link = datetime.utcnow().isoformat() + "Z"
            supabase.table("number_transfer_requests").update(
                {"business_id": target_business_id, "updated_at": now_link}
            ).eq("user_id", user["id"]).in_(
                "status", ["pending_review", "porting"]
            ).is_("business_id", "null").execute()
        except Exception as link_ex:
            logger.warning(
                "[receptionists/create] link open transfer to business failed: %s",
                link_ex,
            )

        logger.info(
            "[receptionists/create] success rec_id=%s staff_ran=%s services_ran=%s promos_ran=%s",
            rec_id, staff_done, services_done, promos_done,
        )
        return {"success": True, "id": rec_id, "phoneNumber": inbound_number}
    except Exception as e:
        # Keep purchased numbers for retry (orphan reclaim) instead of releasing.
        logger.exception("[receptionists/create] failure: %s", e)
        logger.info("[receptionists/create] final result: failure reason=%s", str(e))
        return JSONResponse({"error": str(e)}, status_code=400)


@router.get("/receptionists/{receptionist_id}")
async def get_receptionist(request: Request, receptionist_id: str):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    r = supabase.table("receptionists").select(
        "id, name, phone_number, inbound_phone_number, calendar_id, status, mode, "
        "website_url, extra_instructions, payment_settings, created_at, "
        "system_prompt, greeting, voice_id, voice_preset_key, voice_clone_id, assistant_identity"
    ).eq("id", receptionist_id).single().execute()
    if not r.data:
        return JSONResponse({"error": "Receptionist not found"}, status_code=404)
    data = r.data
    if not (data.get("voice_preset_key") or "").strip():
        inferred = infer_preset_key_from_voice_id((data.get("voice_id") or "").strip() or None)
        if inferred:
            data["voice_preset_key"] = inferred
    return data


@router.get("/google/calendars")
async def list_google_calendars(request: Request):
    """List calendars under the user's connected Google account (for store picker)."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    user_row = (
        supabase.table("users")
        .select("calendar_refresh_token")
        .eq("id", user["id"])
        .single()
        .execute()
    )
    refresh_token = ((user_row.data or {}).get("calendar_refresh_token") or "").strip()
    if not refresh_token:
        return JSONResponse(
            {"error": "Google Calendar is not connected", "calendars": []},
            status_code=400,
        )

    try:
        from google.oauth2.credentials import Credentials
        from google.auth.transport.requests import Request as GoogleAuthRequest
        from googleapiclient.discovery import build

        creds = Credentials(
            token=None,
            refresh_token=refresh_token,
            token_uri="https://oauth2.googleapis.com/token",
            client_id=settings.google_client_id,
            client_secret=settings.google_client_secret,
            scopes=SCOPES,
        )
        creds.refresh(GoogleAuthRequest())
        service = build("calendar", "v3", credentials=creds)
        result = service.calendarList().list().execute()
        items = result.get("items") or []
        calendars = []
        for item in items:
            cid = (item.get("id") or "").strip()
            if not cid:
                continue
            summary = (item.get("summary") or cid).strip()
            cid_l = cid.lower()
            summary_l = summary.lower()
            # Skip Google holiday / read-only calendars — not useful for booking.
            if (
                "#holiday" in cid_l
                or "holiday@group" in cid_l
                or "holidays in" in summary_l
                or summary_l.startswith("holidays ")
            ):
                continue
            role = str(item.get("accessRole") or "").strip().lower()
            if role in ("reader", "freebusyreader"):
                continue
            calendars.append(
                {
                    "id": cid,
                    "summary": summary,
                    "primary": bool(item.get("primary")),
                    "accessRole": item.get("accessRole"),
                }
            )
        return {"calendars": calendars}
    except Exception as e:
        msg = str(e)
        if "invalid_grant" in msg or "Token has been expired" in msg:
            return JSONResponse(
                {
                    "error": "Calendar access expired. Please reconnect Google Calendar.",
                    "calendars": [],
                },
                status_code=400,
            )
        logger.exception("[google/calendars] list failed: %s", e)
        return JSONResponse(
            {"error": "Could not list calendars", "calendars": []},
            status_code=500,
        )


@router.get("/receptionists/{receptionist_id}/calendar-status")
async def receptionist_calendar_status(request: Request, receptionist_id: str):
    """Return calendar connection details for a given receptionist."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    rec = (
        supabase.table("receptionists")
        .select("id, name, user_id, calendar_id, mode")
        .eq("id", receptionist_id)
        .single()
        .execute()
    )
    if not rec.data:
        return JSONResponse({"error": "Receptionist not found"}, status_code=404)

    rec_data = rec.data or {}
    owner_id = rec_data.get("user_id") or user["id"]

    user_row = (
        supabase.table("users")
        .select("email, calendar_id, calendar_refresh_token")
        .eq("id", owner_id)
        .single()
        .execute()
    )
    u = user_row.data or {}

    connected_email = u.get("calendar_id") or u.get("email")
    # Prefer email-shaped values for "Connected as" (not opaque calendar ids).
    if isinstance(connected_email, str) and "@" not in connected_email:
        connected_email = u.get("email") or connected_email
    booking_calendar_id = (rec_data.get("calendar_id") or u.get("calendar_id") or "primary").strip()
    mode = (rec_data.get("mode") or "personal").strip()

    # Prefer a friendly label when the id is opaque.
    if booking_calendar_id == "primary":
        booking_calendar_label = "Primary"
    elif "@" in booking_calendar_id:
        booking_calendar_label = booking_calendar_id
    else:
        booking_calendar_label = "Connected calendar"

    return {
        "connected_google_email": connected_email,
        "booking_calendar_id": booking_calendar_id,
        "booking_calendar_label": booking_calendar_label,
        "mode": mode,
        "assistant_name": rec_data.get("name"),
        "calendar_connected": bool(u.get("calendar_refresh_token")),
    }


@router.patch("/receptionists/{receptionist_id}")
async def update_receptionist(request: Request, receptionist_id: str):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)

    updates = {"updated_at": datetime.utcnow().isoformat() + "Z"}
    mode_changed = False
    if "payment_settings" in body:
        updates["payment_settings"] = body["payment_settings"]
    if "extra_instructions" in body:
        updates["extra_instructions"] = (body["extra_instructions"] or "").strip() or None
    if "system_prompt" in body:
        updates["system_prompt"] = (body["system_prompt"] or "").strip() or None
    if "greeting" in body:
        updates["greeting"] = (body["greeting"] or "").strip() or None
    if "mode" in body:
        mode = (body.get("mode") or "").strip().lower()
        if mode not in ("personal", "business"):
            return JSONResponse(
                {"error": "mode must be personal or business"},
                status_code=400,
            )
        updates["mode"] = mode
        mode_changed = True
    if "voice_preset_key" in body:
        preset_key = (body.get("voice_preset_key") or "").strip() or None
        if preset_key:
            if preset_key not in PRESET_KEYS:
                preset_key = DEFAULT_PRESET_KEY
            resolved = resolve_voice_id(preset_key, None)
            updates["voice_preset_key"] = preset_key
            if resolved is not None:
                updates["voice_id"] = resolved
        else:
            # Explicitly clearing preset label should not swap voices.
            updates["voice_preset_key"] = None
    elif "voice_id" in body:
        updates["voice_id"] = (body["voice_id"] or "").strip() or None
    if "voice_clone_id" in body:
        raw_clone = body.get("voice_clone_id")
        if raw_clone is None or (isinstance(raw_clone, str) and not raw_clone.strip()):
            updates["voice_clone_id"] = None
        else:
            clone_id = str(raw_clone).strip()
            clone_err = assert_owned_clone(supabase, user["id"], clone_id)
            if clone_err:
                return JSONResponse({"error": clone_err}, status_code=400)
            updates["voice_clone_id"] = clone_id
    if "assistant_identity" in body:
        updates["assistant_identity"] = (body["assistant_identity"] or "").strip() or None

    if len(updates) <= 1:
        return {"ok": True}
    supabase.table("receptionists").update(updates).eq("id", receptionist_id).execute()
    if "voice_preset_key" in updates or "voice_id" in updates:
        logger.info(
            "[receptionists/update] voice resolved rec_id=%s preset_key=%s voice_id=%s",
            receptionist_id,
            updates.get("voice_preset_key"),
            updates.get("voice_id"),
        )
    if mode_changed:
        try:
            rec = (
                supabase.table("receptionists")
                .select("business_id")
                .eq("id", receptionist_id)
                .limit(1)
                .execute()
            )
            business_id = None
            if rec.data:
                business_id = (rec.data[0] or {}).get("business_id")
            if business_id:
                ensure_business_communication(supabase, str(business_id))
        except Exception as ex:
            logger.warning(
                "[receptionists/update] ensure_business_communication after mode change failed: %s",
                ex,
            )
    return {"ok": True, "mode": updates.get("mode")}


@router.post("/receptionists/{receptionist_id}/delete")
async def delete_receptionist(request: Request, receptionist_id: str):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    rec = (
        supabase.table("receptionists")
        .select(
            "name, telnyx_phone_number_id, inbound_phone_number, status, deleted_at, active, user_id, business_id"
        )
        .eq("id", receptionist_id)
        .single()
        .execute()
    )
    data = rec.data or {}
    owner_id = str(data.get("user_id") or user["id"])
    business_id_for_refresh = data.get("business_id")

    # Manual release (C3): do not auto-release Telnyx. If this was the last
    # active receptionist on the number, notify ops to release within 24–48h.
    telnyx_id = data.get("telnyx_phone_number_id")
    inbound_phone = data.get("inbound_phone_number")
    needs_manual_release = False
    if telnyx_id or inbound_phone:
        others_q = (
            supabase.table("receptionists")
            .select("id")
            .eq("user_id", owner_id)
            .neq("id", receptionist_id)
            .eq("status", "active")
            .eq("active", True)
            .is_("deleted_at", "null")
            .limit(1)
        )
        if telnyx_id:
            others_q = others_q.eq("telnyx_phone_number_id", telnyx_id)
        elif inbound_phone:
            others_q = others_q.eq("inbound_phone_number", inbound_phone)
        others = others_q.execute()
        needs_manual_release = not (others.data or [])

    # Soft delete receptionist: keep history, hide from UI/routing
    now_iso = datetime.utcnow().isoformat() + "Z"
    updates: dict[str, object] = {
        "status": "paused",
        "active": False,
        "deleted_at": now_iso,
        "updated_at": now_iso,
    }
    supabase.table("receptionists").update(updates).eq("id", receptionist_id).execute()

    # One DID per account: park it on the business line, detach from this row
    # so we can reclaim without buying, and ops can later return it to the pool.
    if needs_manual_release and business_id_for_refresh and (telnyx_id or inbound_phone):
        try:
            upsert_canonical_business_phone(
                supabase,
                str(business_id_for_refresh),
                phone_number_e164=inbound_phone,
                telnyx_number_id=telnyx_id,
            )
        except Exception as ex:
            logger.warning("[delete] keep canonical DID failed: %s", ex)
        try:
            from telnyx.phone_lifecycle import detach_phone_from_receptionist

            detach_phone_from_receptionist(supabase, receptionist_id)
        except Exception as ex:
            logger.warning("[delete] detach DID from receptionist failed: %s", ex)

    try:
        if business_id_for_refresh:
            refresh_business_after_primary_receptionist_removed(supabase, str(business_id_for_refresh))
        else:
            ensure_communication_for_user_after_receptionist_change(supabase, owner_id)
    except Exception as ex:
        logger.warning("[delete] communication refresh failed: %s", ex)

    if needs_manual_release:
        owner_email = None
        try:
            ures = (
                supabase.table("users")
                .select("email")
                .eq("id", owner_id)
                .limit(1)
                .execute()
            )
            if ures.data:
                owner_email = (ures.data[0] or {}).get("email")
        except Exception as ex:
            logger.warning("[delete] failed to load owner email for notify: %s", ex)
        try:
            from utils.internal_notify import notify_phone_number_release_needed

            notify_phone_number_release_needed(
                receptionist_id=receptionist_id,
                receptionist_name=data.get("name"),
                phone_number=inbound_phone,
                telnyx_phone_number_id=telnyx_id,
                owner_user_id=owner_id,
                owner_email=owner_email,
                business_id=str(business_id_for_refresh) if business_id_for_refresh else None,
            )
        except Exception as ex:
            logger.warning("[delete] release notify failed: %s", ex)

    return {
        "success": True,
        "message": (
            "Receptionist deleted. Your number is held so you can attach it to a new "
            "receptionist. If you don't reuse it, we'll release it within 24–48 hours."
            if needs_manual_release
            else "Receptionist deleted. Calls will no longer route to this receptionist."
        ),
        "number_release_pending": needs_manual_release,
        "held_phone_number": inbound_phone if needs_manual_release else None,
    }


@router.get("/phone-numbers/pending-release")
async def list_pending_release_numbers(request: Request):
    """Soft-deleted assistants still holding a DID — reclaimable on create."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    from telnyx.phone_lifecycle import (
        can_purchase_extra_number,
        collect_account_phone_inventory,
        list_pending_release_numbers_for_user,
    )

    numbers = list_pending_release_numbers_for_user(supabase, user["id"])
    inventory = collect_account_phone_inventory(supabase, user["id"])
    return {
        "numbers": numbers,
        "can_purchase_extra": can_purchase_extra_number(inventory),
    }


@router.post("/receptionists/{receptionist_id}/website")
async def receptionist_website(request: Request, receptionist_id: str):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
    url = (body.get("url") or "").strip()
    if not url:
        return JSONResponse({"error": "Please enter a website URL."}, status_code=400)

    if not url.startswith("http://") and not url.startswith("https://"):
        return JSONResponse({"error": "Invalid URL."}, status_code=400)

    try:
        with httpx.Client(timeout=10.0) as client:
            r = client.get(url, headers={"User-Agent": "Mozilla/5.0 (compatible; AIReceptionist/1.0)"}, follow_redirects=True)
            if r.status_code != 200:
                return JSONResponse({"error": f"Could not fetch: {r.status_code}"}, status_code=400)
            html = r.text
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=400)

    text = re.sub(r"<script[^>]*>[\s\S]*?</script>", "", html, flags=re.I)
    text = re.sub(r"<style[^>]*>[\s\S]*?</style>", "", text, flags=re.I)
    text = re.sub(r"<head[^>]*>[\s\S]*?</head>", "", text, flags=re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()[:15000]
    if not text:
        return JSONResponse({"error": "No text content could be extracted."}, status_code=400)

    supabase.table("receptionists").update({
        "website_url": url,
        "website_content": text,
        "website_content_updated_at": datetime.utcnow().isoformat() + "Z",
        "updated_at": datetime.utcnow().isoformat() + "Z",
    }).eq("id", receptionist_id).execute()
    return {"ok": True}


# --- Appointments (review workflow) ---
def _get_user_receptionist_ids(supabase, user_id: str) -> list[str]:
    """Return list of receptionist IDs owned by user."""
    r = (
        supabase.table("receptionists")
        .select("id")
        .eq("user_id", user_id)
        .is_("deleted_at", "null")
        .execute()
    )
    return [row["id"] for row in (r.data or []) if row.get("id")]


def _assert_appointment_ownership(appointment_id: str, user_id: str, supabase) -> str | None:
    """Return None if user owns the appointment (via receptionist), else error string."""
    r = (
        supabase.table("appointments")
        .select("id, receptionist_id")
        .eq("id", appointment_id)
        .single()
        .execute()
    )
    if not r.data:
        return "Appointment not found"
    rec_id = r.data.get("receptionist_id")
    if not rec_id:
        return "Appointment not found"
    err = _assert_receptionist_ownership(rec_id, user_id, supabase)
    return err


@router.get("/appointments")
async def list_appointments(request: Request):
    """List upcoming appointments for user's receptionists. Optional status filter."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    rec_ids = _get_user_receptionist_ids(supabase, user["id"])
    if not rec_ids:
        return {"appointments": [], "receptionists": {}}

    status_filter = request.query_params.get("status")
    receptionist_filter = request.query_params.get("receptionist_id")
    limit = min(int(request.query_params.get("limit", 50)), 100)
    offset = max(0, int(request.query_params.get("offset", 0)))
    rec_ids_filter = rec_ids
    if receptionist_filter and receptionist_filter in rec_ids:
        rec_ids_filter = [receptionist_filter]

    appointments = []
    used_reduced_select = False
    try:
        q = (
            supabase.table("appointments")
            .select(APPOINTMENTS_FULL_SELECT)
            .in_("receptionist_id", rec_ids_filter)
            .order("start_time", desc=False)
            .range(offset, offset + limit - 1)
        )
        if status_filter and status_filter in ("confirmed", "needs_review", "cancelled", "completed"):
            q = q.eq("status", status_filter)
        rows = q.execute()
        appointments = rows.data or []
    except Exception as e:
        if _is_missing_column_error(e):
            logger.warning(
                "[APPOINTMENTS_SCHEMA_FALLBACK] missing_columns=030 optional using_reduced_select=true error=%s",
                str(e)[:200],
            )
            try:
                q = (
                    supabase.table("appointments")
                    .select(APPOINTMENTS_BASE_SELECT)
                    .in_("receptionist_id", rec_ids_filter)
                    .order("start_time", desc=False)
                    .range(offset, offset + limit - 1)
                )
                rows = q.execute()
                appointments = rows.data or []
                used_reduced_select = True
            except Exception as retry_exc:
                logger.exception("[APPOINTMENTS] list fallback failed: %s", retry_exc)
                return {"appointments": [], "receptionists": {}}
        else:
            logger.exception("[appointments] list failed: %s", e)
            return {"appointments": [], "receptionists": {}}

    if used_reduced_select:
        for a in appointments:
            a.setdefault("status", "needs_review")
            a.setdefault("caller_number", None)
            a.setdefault("confirmation_message_sent_at", None)
            a.setdefault("payment_link_sent_at", None)
        logger.info(
            "[APPOINTMENTS_SCHEMA_FALLBACK] using_reduced_select=true count=%s (apply migration 030)",
            len(appointments),
        )

    rec_rows = (
        supabase.table("receptionists")
        .select("id, name")
        .in_("id", list({a["receptionist_id"] for a in appointments}))
        .execute()
    )
    receptionists = {r["id"]: r.get("name") or "Receptionist" for r in (rec_rows.data or [])}

    return {"appointments": appointments, "receptionists": receptionists}


@router.get("/appointments/{appointment_id}")
async def get_appointment(request: Request, appointment_id: str):
    """Get single appointment with receptionist and optional call transcript."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_appointment_ownership(appointment_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    try:
        r = (
            supabase.table("appointments")
            .select(APPOINTMENTS_FULL_SELECT)
            .eq("id", appointment_id)
            .single()
            .execute()
        )
    except Exception as e:
        if _is_missing_column_error(e):
            try:
                r = (
                    supabase.table("appointments")
                    .select(APPOINTMENTS_BASE_SELECT)
                    .eq("id", appointment_id)
                    .single()
                    .execute()
                )
            except Exception as retry_exc:
                logger.exception("[appointments] get fallback failed: %s", retry_exc)
                return JSONResponse({"error": str(retry_exc)}, status_code=500)
        else:
            logger.exception("[appointments] get failed: %s", e)
            return JSONResponse({"error": str(e)}, status_code=500)

    if not r or not r.data:
        return JSONResponse({"error": "Appointment not found"}, status_code=404)

    apt = dict(r.data)
    for key in ("status", "caller_number", "call_log_id", "confirmation_message_sent_at", "payment_link_sent_at"):
        if key not in apt:
            apt[key] = None
    apt.setdefault("status", "needs_review")

    rec_id = apt.get("receptionist_id")
    if rec_id:
        rec_r = supabase.table("receptionists").select("id, name").eq("id", rec_id).single().execute()
        apt["receptionist_name"] = (rec_r.data or {}).get("name") or "Receptionist"
    else:
        apt["receptionist_name"] = "—"

    call_log_id = apt.get("call_log_id")
    if call_log_id:
        try:
            cl = supabase.table("call_logs").select("transcript").eq("id", call_log_id).single().execute()
            apt["transcript"] = (cl.data or {}).get("transcript")
        except Exception:
            apt["transcript"] = None
    else:
        apt["transcript"] = None

    try:
        sms_rows = (
            supabase.table("sms_messages")
            .select("status")
            .eq("appointment_id", appointment_id)
            .order("created_at", desc=True)
            .limit(1)
            .execute()
        )
        if sms_rows and sms_rows.data and len(sms_rows.data) > 0:
            apt["sms_delivery_status"] = sms_rows.data[0].get("status") or "sent"
        else:
            apt["sms_delivery_status"] = None
    except Exception:
        apt["sms_delivery_status"] = None

    return apt


@router.patch("/appointments/{appointment_id}")
async def update_appointment(request: Request, appointment_id: str):
    """Update appointment: confirm, reject, edit service/notes, attach payment link, etc."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_appointment_ownership(appointment_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)

    updates = {"updated_at": datetime.utcnow().isoformat() + "Z"}
    if "status" in body and body["status"] in ("confirmed", "needs_review", "cancelled", "completed"):
        updates["status"] = body["status"]
    if "service_name" in body:
        updates["service_name"] = (body["service_name"] or "").strip() or None
    if "notes" in body:
        updates["notes"] = (body["notes"] or "").strip() or None
    if "payment_link" in body:
        updates["payment_link"] = (body["payment_link"] or "").strip() or None
    if "location_text" in body:
        updates["location_text"] = (body["location_text"] or "").strip() or None
    if "customer_address" in body:
        updates["customer_address"] = (body["customer_address"] or "").strip() or None
    if "internal_followup_notes" in body:
        updates["internal_followup_notes"] = (body["internal_followup_notes"] or "").strip() or None
    if "meeting_instructions" in body:
        updates["meeting_instructions"] = (body["meeting_instructions"] or "").strip() or None

    if len(updates) <= 1:
        return {"ok": True}

    supabase.table("appointments").update(updates).eq("id", appointment_id).execute()
    return {"ok": True}


@router.post("/appointments/{appointment_id}/send-confirmation")
async def send_appointment_confirmation_route(request: Request, appointment_id: str):
    """Send confirmation SMS to the appointment caller. Optional body: { message?: string }."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_appointment_ownership(appointment_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    try:
        body = await request.json() if request.headers.get("content-length", "0") != "0" else {}
    except Exception:
        body = {}

    message = (body.get("message") or "").strip() or None

    r = (
        supabase.table("appointments")
        .select(
            "id, receptionist_id, caller_number, followup_message_resolved, "
            "payment_link, meeting_instructions, customer_address, location_text"
        )
        .eq("id", appointment_id)
        .single()
        .execute()
    )
    if not r.data:
        return JSONResponse({"error": "Appointment not found"}, status_code=404)

    from api.appointment_followup import send_appointment_confirmation

    result = send_appointment_confirmation(supabase, r.data, message=message)
    if not result.get("success"):
        return JSONResponse(
            {"success": False, "error": result.get("error", "Failed to send")},
            status_code=400,
        )
    return {"success": True}


def _is_missing_column_error(exc: BaseException) -> bool:
    """True if error indicates a missing column (schema not migrated)."""
    return is_missing_column_error(exc)


@router.get("/receptionists/{receptionist_id}/call-history")
async def get_call_history(request: Request, receptionist_id: str):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    limit = min(int(request.query_params.get("limit", 50)), 100)
    offset = max(0, int(request.query_params.get("offset", 0)))

    try:
        calls, select_mode, degraded_reason = fetch_call_logs_with_fallback(
            supabase=supabase,
            receptionist_ids=[receptionist_id],
            limit=limit,
            offset=offset,
            completed_only=False,
            diag_tag="receptionist-call-history",
        )
    except RuntimeError:
        logger.error(
            "[CALL_HISTORY_SCHEMA_FALLBACK] no_compatible_select receptionist_id=%s last_error=%s",
            receptionist_id,
            "schema mismatch",
        )
        return JSONResponse(
            {
                "error": "Call history unavailable due to schema mismatch",
                "code": "call_history_schema_mismatch",
                "degraded": True,
            },
            status_code=503,
        )
    except Exception as e:
        logger.exception("[CALL_DIAG] call-history failed receptionist_id=%s: %s", receptionist_id, e)
        return JSONResponse(
            {
                "error": "Failed to load call history",
                "code": "call_history_query_failed",
            },
            status_code=500,
        )

    # Resolve appointment_id for each call (appointments.call_log_id = call.id)
    call_ids = [c["id"] for c in (calls or []) if c.get("id")]
    appointment_by_call = {}
    if call_ids:
        try:
            apt_rows = (
                supabase.table("appointments")
                .select("id, call_log_id")
                .in_("call_log_id", call_ids)
                .execute()
            )
            for a in (apt_rows.data or []):
                clid = a.get("call_log_id")
                if clid:
                    appointment_by_call[str(clid)] = a.get("id")
        except Exception:
            pass
    # Defensive: ensure each row has expected fields, coerce None duration
    safe_calls = []
    for safe in (calls or []):
        call_id = safe.get("id")
        if call_id and str(call_id) in appointment_by_call:
            safe["appointment_id"] = appointment_by_call[str(call_id)]
        safe_calls.append(safe)
    logger.info(
        "[CALL_DIAG] call-history receptionist_id=%s count=%s offset=%s select_mode=%s",
        receptionist_id, len(safe_calls), offset, select_mode,
    )
    response = {"calls": safe_calls}
    if select_mode != "full":
        response["degraded"] = True
        response["degraded_reason"] = (
            "schema_fallback_active: optional call columns unavailable; apply migrations 031 and 032"
        )
        response["select_mode"] = select_mode
    return response


@router.get("/receptionists/{receptionist_id}/calls/{call_id}")
async def get_call_detail(request: Request, receptionist_id: str, call_id: str):
    """Fetch a single call for cold open / deep link when list extra is missing."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    try:
        call, select_mode, _degraded_reason = fetch_call_log_by_id_with_fallback(
            supabase=supabase,
            receptionist_id=receptionist_id,
            call_id=call_id,
            diag_tag="call-detail",
        )
    except RuntimeError:
        return JSONResponse(
            {
                "error": "Call details unavailable due to schema mismatch",
                "code": "call_history_schema_mismatch",
            },
            status_code=503,
        )
    except Exception as e:
        logger.exception(
            "[CALL_DIAG] call-detail failed receptionist_id=%s call_id=%s: %s",
            receptionist_id,
            call_id,
            e,
        )
        return JSONResponse({"error": "Failed to load call"}, status_code=500)

    if not call:
        return JSONResponse({"error": "Call not found"}, status_code=404)

    try:
        apt_rows = (
            supabase.table("appointments")
            .select("id, call_log_id")
            .eq("call_log_id", call_id)
            .limit(1)
            .execute()
        )
        rows = apt_rows.data if apt_rows and isinstance(apt_rows.data, list) else []
        if rows and rows[0].get("id"):
            call["appointment_id"] = rows[0]["id"]
    except Exception:
        pass

    response = {"call": call}
    if select_mode != "full":
        response["degraded"] = True
        response["select_mode"] = select_mode
    return response


@router.get("/receptionists/{receptionist_id}/calls/{call_id}/recording-url")
async def get_call_recording_url(request: Request, receptionist_id: str, call_id: str):
    """Return a freshly minted Telnyx recording download URL (short-lived; do not cache)."""
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    row: dict | None = None
    select_full = "id, receptionist_id, call_control_id, recording_status, telnyx_recording_id"
    select_base = "id, receptionist_id, call_control_id, recording_status"
    for sel in (select_full, select_base):
        try:
            r = (
                supabase.table("call_logs")
                .select(sel)
                .eq("id", call_id)
                .eq("receptionist_id", receptionist_id)
                .limit(1)
                .execute()
            )
            rows = r.data if r and isinstance(r.data, list) else []
            if not rows:
                return JSONResponse({"error": "Call not found"}, status_code=404)
            row = rows[0]
            break
        except Exception as e:
            if sel == select_full and _is_missing_column_error(e):
                logger.warning(
                    "[recording-url] telnyx_recording_id unavailable (migration 033?): %s",
                    str(e)[:180],
                )
                continue
            logger.exception("[recording-url] call_logs query failed receptionist_id=%s call_id=%s", receptionist_id, call_id)
            return JSONResponse({"error": "Failed to load call"}, status_code=500)

    if not row:
        return JSONResponse({"error": "Call not found"}, status_code=404)

    status = (row.get("recording_status") or "").strip().lower()
    if status != "available":
        return JSONResponse(
            {
                "error": "Recording not available for this call",
                "recording_status": status or "unknown",
            },
            status_code=409,
        )

    api_key = (settings.telnyx_api_key or "").strip()
    url = await fetch_fresh_recording_mp3_url(
        api_key=api_key,
        telnyx_recording_id=row.get("telnyx_recording_id"),
        call_control_id=row.get("call_control_id"),
    )
    if not url:
        return JSONResponse(
            {"error": "Could not retrieve a fresh recording link. Try again later."},
            status_code=502,
        )
    return {"url": url}


@router.get("/receptionists/{receptionist_id}/prompt-preview")
async def prompt_preview(request: Request, receptionist_id: str):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    err = _assert_receptionist_ownership(receptionist_id, user["id"], supabase)
    if err:
        return JSONResponse({"error": err}, status_code=404)

    try:
        prompt, greeting, *_ = _build_from_supabase_sync(receptionist_id, supabase)
        compact = request.query_params.get("compact", "").lower() == "true"
        return {"prompt": prompt, "greeting": greeting, "charCount": len(prompt)}
    except Exception as e:
        logger.exception("[prompt-preview] %s", e)
        return JSONResponse({"error": str(e)}, status_code=400)


## dashboard-summary and settings routes moved to api/mobile/*
