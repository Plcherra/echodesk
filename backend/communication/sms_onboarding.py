"""SMS / 10DLC onboarding: Telnyx brand, campaign, phone link. States stay honest (no fake approval)."""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any

from config import settings
from telnyx import ten_dlc

logger = logging.getLogger(__name__)


def _now_iso() -> str:
    return datetime.utcnow().isoformat() + "Z"


def _load_owner_and_business(supabase: Any, business_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    bres = supabase.table("businesses").select("id, owner_user_id, name").eq("id", business_id).limit(1).execute()
    brows = bres.data or []
    if not brows:
        raise ValueError("business_not_found")
    business = brows[0]
    uid = str(business["owner_user_id"])
    ures = supabase.table("users").select("email, business_name, business_address").eq("id", uid).single().execute()
    user = ures.data or {}
    return user, business


def _default_registration_profile(
    user: dict[str, Any], business: dict[str, Any], existing: dict[str, Any] | None
) -> dict[str, Any]:
    profile = dict(existing or {})
    bn = (business.get("name") or user.get("business_name") or "").strip()
    if bn:
        profile.setdefault("display_name", bn)
        profile.setdefault("company_name", bn)
    em = (user.get("email") or "").strip()
    if em:
        profile.setdefault("email", em)
    addr = (user.get("business_address") or "").strip()
    if addr and "street" not in profile:
        parts = [p.strip() for p in addr.split(",") if p.strip()]
        if len(parts) >= 3:
            profile.setdefault("street", parts[0])
            profile.setdefault("city", parts[1])
            tail = parts[2].split()
            if len(tail) >= 2:
                profile.setdefault("state", tail[0])
                profile.setdefault("postal_code", tail[1])
        elif len(parts) == 1:
            profile.setdefault("street", parts[0])
    profile.setdefault("country", "US")
    profile.setdefault("entity_type", "PRIVATE_PROFIT")
    profile.setdefault("vertical", (settings.telnyx_10dlc_default_vertical or "RETAIL").strip() or "RETAIL")
    profile.setdefault("usecase", (settings.telnyx_10dlc_default_usecase or "CUSTOMER_CARE").strip() or "CUSTOMER_CARE")
    if not (profile.get("description") or "").strip():
        profile["description"] = (
            f"{bn or 'The business'} sends non-marketing customer care SMS to its own customers. "
            "Messages are related to appointments and service requests, including booking confirmations, "
            "reminders, rescheduling or cancellation updates, and customer support replies."
        )
    if not (profile.get("message_flow") or "").strip():
        profile["message_flow"] = (
            f"Customers opt in directly with {bn or 'the business'}, not with EchoDesk as a shared sender. "
            "Primary opt-in is verbal during an inbound or outbound scheduling call: the customer calls the "
            "business phone number or asks to book an appointment, and the receptionist asks, "
            "\"Would you like a text confirmation and appointment updates from us? Message and data rates may "
            "apply. Reply STOP to opt out or HELP for help.\" SMS is sent only after the customer agrees. "
            "Customers may also opt in by texting the published business phone number first; that inbound SMS "
            "starts a two-way appointment support conversation. Message frequency varies by appointment activity."
        )
    if not (profile.get("sample1") or "").strip():
        profile["sample1"] = (
            f"{bn or 'Business'}: Your appointment is confirmed for Monday at 2:00 PM. Reply STOP to opt out, HELP for help."
        )
    if not (profile.get("sample2") or "").strip():
        profile["sample2"] = (
            f"{bn or 'Business'}: Reminder, your appointment is tomorrow at 2:00 PM. "
            "Reply STOP to opt out, HELP for help."
        )
    profile.setdefault("optout_keywords", "STOP")
    profile.setdefault("help_keywords", "HELP")
    profile.setdefault(
        "help_message",
        "Reply STOP to unsubscribe. Reply HELP for assistance.",
    )
    profile.setdefault(
        "optout_message",
        "You have been unsubscribed from messages from this business.",
    )
    return profile


def _validate_for_submit(profile: dict[str, Any], e164: str | None) -> str | None:
    if not (e164 or "").strip():
        return "Business phone number is not active yet. Finish voice setup first."
    mp = (settings.telnyx_messaging_profile_id or "").strip()
    if not mp:
        return "Server missing TELNYX_MESSAGING_PROFILE_ID (required to register SMS on your number)."
    for key in ("email", "display_name", "country", "vertical", "usecase", "description", "message_flow", "sample1"):
        if not (profile.get(key) or "").strip():
            return f"SMS registration incomplete: missing '{key}'. Update registration in Communication setup or PATCH /communication/sms/registration."
    et = (profile.get("entity_type") or "").strip().upper()
    if et != "SOLE_PROPRIETOR":
        if not (profile.get("company_name") or "").strip():
            return "Missing company_name for brand registration."
    return None


def merge_registration_profile(
    supabase: Any, business_id: str, patch: dict[str, Any]
) -> tuple[bool, str | None]:
    res = supabase.table("sms_campaigns").select("registration_profile").eq("business_id", business_id).limit(1).execute()
    rows = res.data or []
    if not rows:
        return False, "SMS campaign row missing"
    cur = dict(rows[0].get("registration_profile") or {})
    for k, v in patch.items():
        if v is None:
            cur.pop(k, None)
        else:
            cur[k] = v
    supabase.table("sms_campaigns").update(
        {"registration_profile": cur, "updated_at": _now_iso()}
    ).eq("business_id", business_id).execute()
    return True, None


def activate_sms(supabase: Any, business_id: str) -> tuple[bool, str | None, str | None]:
    """not_started -> needs_submission; seed registration_profile from user/business."""
    res = supabase.table("sms_campaigns").select("id, status, registration_profile").eq("business_id", business_id).limit(1).execute()
    rows = res.data or []
    if not rows:
        return False, "SMS campaign row missing", None
    st = (rows[0].get("status") or "").strip()
    if st != "not_started":
        return False, f"SMS already {st}", None

    try:
        user, business = _load_owner_and_business(supabase, business_id)
    except ValueError:
        return False, "Business not found", None

    profile = _default_registration_profile(user, business, rows[0].get("registration_profile"))
    supabase.table("sms_campaigns").update(
        {
            "status": "needs_submission",
            "failure_reason": None,
            "registration_profile": profile,
            "updated_at": _now_iso(),
        }
    ).eq("business_id", business_id).execute()
    logger.info("[sms_onboarding] not_started -> needs_submission business_id=%s", business_id)
    return True, None, "needs_submission"


def _brand_request_body(profile: dict[str, Any], e164: str) -> dict[str, Any]:
    et = (profile.get("entity_type") or "PRIVATE_PROFIT").strip()
    body: dict[str, Any] = {
        "entityType": et,
        "displayName": (profile.get("display_name") or "").strip(),
        "email": (profile.get("email") or "").strip(),
        "country": (profile.get("country") or "US").strip(),
        "vertical": (profile.get("vertical") or "RETAIL").strip(),
        "phone": (profile.get("phone") or e164).strip(),
    }
    if (profile.get("website") or "").strip():
        body["website"] = profile["website"].strip()
    if et != "SOLE_PROPRIETOR":
        cn = (profile.get("company_name") or "").strip()
        if cn:
            body["companyName"] = cn
        ein = (profile.get("ein") or "").strip()
        if ein:
            body["ein"] = ein
    for src, dst in (
        ("street", "street"),
        ("city", "city"),
        ("state", "state"),
        ("postal_code", "postalCode"),
    ):
        if (profile.get(src) or "").strip():
            body[dst] = profile[src].strip()
    if profile.get("mobile_phone"):
        body["mobilePhone"] = str(profile["mobile_phone"]).strip()
    if settings.telnyx_10dlc_use_mock:
        body["mock"] = True
    return body


def _campaign_request_body(brand_id: str, profile: dict[str, Any]) -> dict[str, Any]:
    return {
        "brandId": brand_id,
        "usecase": (profile.get("usecase") or "CUSTOMER_CARE").strip(),
        "description": (profile.get("description") or "").strip(),
        "messageFlow": (profile.get("message_flow") or "").strip(),
        "sample1": (profile.get("sample1") or "").strip(),
        "sample2": (profile.get("sample2") or profile.get("sample1") or "").strip(),
        "subscriberOptout": True,
        "subscriberHelp": True,
        "optoutKeywords": (profile.get("optout_keywords") or "STOP").strip(),
        "helpKeywords": (profile.get("help_keywords") or "HELP").strip(),
        "helpMessage": (profile.get("help_message") or "Reply STOP to opt out.").strip(),
        "optoutMessage": (profile.get("optout_message") or "You are unsubscribed.").strip(),
    }


def _mark_failed(supabase: Any, business_id: str, reason: str) -> None:
    supabase.table("sms_campaigns").update(
        {"status": "failed", "failure_reason": reason[:2000], "updated_at": _now_iso()}
    ).eq("business_id", business_id).execute()


def submit_sms_registration(
    supabase: Any,
    business_id: str,
    *,
    profile_patch: dict[str, Any] | None = None,
) -> tuple[bool, str | None, str | None]:
    """
    needs_submission -> Telnyx brand + campaign + phone link -> pending_review (carrier review, not approval).
    """
    res = (
        supabase.table("sms_campaigns")
        .select("*")
        .eq("business_id", business_id)
        .limit(1)
        .execute()
    )
    rows = res.data or []
    if not rows:
        return False, "SMS campaign row missing", None
    row = rows[0]
    st = (row.get("status") or "").strip()
    if st != "needs_submission":
        return False, "Complete the previous SMS step first.", None

    phone_res = (
        supabase.table("business_phone_numbers")
        .select("phone_number_e164, telnyx_number_id, status")
        .eq("business_id", business_id)
        .limit(1)
        .execute()
    )
    phone_rows = phone_res.data or []
    phone = phone_rows[0] if phone_rows else {}
    e164 = (phone.get("phone_number_e164") or "").strip() or None
    telnyx_pid = (phone.get("telnyx_number_id") or "").strip() or None

    try:
        user, business = _load_owner_and_business(supabase, business_id)
    except ValueError:
        return False, "Business not found", None

    profile = _default_registration_profile(user, business, row.get("registration_profile"))
    if profile_patch:
        profile.update({k: v for k, v in profile_patch.items() if v is not None})

    err = _validate_for_submit(profile, e164)
    if err:
        return False, err, None

    supabase.table("sms_campaigns").update(
        {"registration_profile": profile, "updated_at": _now_iso()}
    ).eq("business_id", business_id).execute()

    try:
        if telnyx_pid and (settings.telnyx_messaging_profile_id or "").strip():
            ten_dlc.set_phone_messaging_profile(telnyx_pid, settings.telnyx_messaging_profile_id)

        brand_id = (row.get("brand_id") or "").strip() or None
        if not brand_id:
            bbody = _brand_request_body(profile, e164 or "")
            brec = ten_dlc.create_brand(bbody)
            brand_id = ten_dlc.extract_id(brec, "id", "brandId", "brand_id")
            if not brand_id:
                _mark_failed(supabase, business_id, "Telnyx brand response missing id")
                return False, "Telnyx did not return a brand id", None

        binfo = ten_dlc.get_brand(brand_id)
        bstatus = (binfo.get("status") or binfo.get("identityStatus") or "").strip()
        supabase.table("sms_campaigns").update(
            {"brand_id": brand_id, "provider_brand_status": bstatus or None, "updated_at": _now_iso()}
        ).eq("business_id", business_id).execute()

        if bstatus and "FAIL" in bstatus.upper():
            _mark_failed(supabase, business_id, f"Brand registration failed: {bstatus}")
            return False, f"Brand status: {bstatus}", None

        campaign_id = (row.get("campaign_id") or "").strip() or None
        crec: dict[str, Any] = {}
        if not campaign_id:
            cbody = _campaign_request_body(brand_id, profile)
            crec = ten_dlc.submit_campaign(cbody)
            campaign_id = ten_dlc.extract_id(crec, "id", "campaignId", "campaign_id")
            if not campaign_id:
                _mark_failed(supabase, business_id, "Telnyx campaign response missing id")
                return False, "Telnyx did not return a campaign id", None

        cstatus = (crec.get("status") or crec.get("tcrCampaignStatus") or "").strip()
        if not cstatus:
            cstatus = (row.get("provider_campaign_status") or "").strip()
        supabase.table("sms_campaigns").update(
            {
                "campaign_id": campaign_id,
                "provider_campaign_status": cstatus or None,
                "updated_at": _now_iso(),
            }
        ).eq("business_id", business_id).execute()

        if e164 and campaign_id:
            try:
                ten_dlc.link_phone_number_to_campaign(e164, campaign_id)
            except ValueError as link_ex:
                logger.warning("[sms_onboarding] campaign phone link: %s", link_ex)

        now = _now_iso()
        supabase.table("sms_campaigns").update(
            {
                "status": "pending_review",
                "failure_reason": None,
                "last_submitted_at": now,
                "updated_at": now,
            }
        ).eq("business_id", business_id).execute()
        logger.info(
            "[sms_onboarding] submitted to Telnyx business_id=%s brand=%s campaign=%s",
            business_id,
            brand_id,
            campaign_id,
        )
        return True, None, "pending_review"

    except ValueError as ex:
        _mark_failed(supabase, business_id, str(ex))
        return False, str(ex), None
    except Exception as ex:
        logger.exception("[sms_onboarding] submit failed business_id=%s", business_id)
        _mark_failed(supabase, business_id, str(ex))
        return False, str(ex), None


def retry_sms(supabase: Any, business_id: str) -> tuple[bool, str | None, str | None]:
    """failed -> needs_submission (keep brand/campaign ids for support; user fixes profile and resubmits)."""
    res = supabase.table("sms_campaigns").select("id, status").eq("business_id", business_id).limit(1).execute()
    rows = res.data or []
    if not rows:
        return False, "SMS campaign row missing", None
    st = (rows[0].get("status") or "").strip()
    if st != "failed":
        return False, "Retry is only available after a failed registration.", None

    updates = {
        "status": "needs_submission",
        "failure_reason": None,
        "updated_at": _now_iso(),
    }
    supabase.table("sms_campaigns").update(updates).eq("business_id", business_id).execute()
    logger.info("[sms_onboarding] failed -> needs_submission business_id=%s", business_id)
    return True, None, "needs_submission"
