"""Build GET /communication/setup payload: status + server-derived onboarding guidance."""

from __future__ import annotations

from typing import Any, Literal

NextRecommendedAction = Literal[
    "create_receptionist",
    "check_voice",
    "activate_sms",
    "submit_sms",
    "check_sms",
    "connect_whatsapp",
    "continue_whatsapp",
    "check_whatsapp",
    "retry_sms",
    "retry_whatsapp",
    "none",
]


def _effective_voice_status(phone: dict[str, Any], e164: str | None) -> str:
    st = (phone.get("status") or "not_started").strip()
    # A live E.164 means the line is usable even if status lags on "provisioning".
    if e164 and st != "failed":
        return "active"
    if st == "active" and e164:
        return "active"
    if st == "failed":
        return "failed"
    if st == "provisioning":
        return "provisioning"
    return "not_started"


def _voice_guidance(status: str) -> dict[str, str | None]:
    if status == "active":
        return {
            "voice_setup_title": "Business line ready",
            "voice_setup_description": "Callers can reach your AI receptionist on this number.",
            "voice_primary_action": "",
            "voice_help_text": None,
        }
    if status == "provisioning":
        return {
            "voice_setup_title": "Assigning your business number",
            "voice_setup_description": (
                "We're setting up your US business line. This can take up to a minute."
            ),
            "voice_primary_action": "Refresh status",
            "voice_help_text": "If the number hasn't appeared yet, tap Refresh.",
        }
    if status == "failed":
        return {
            "voice_setup_title": "Phone setup needs attention",
            "voice_setup_description": "We couldn't finish setting up your business line.",
            "voice_primary_action": "Retry phone setup",
            "voice_help_text": "Create or retry your first receptionist to set up the shared business line.",
        }
    return {
        "voice_setup_title": "No business number yet",
        "voice_setup_description": "Create your first receptionist to set up your shared business line.",
        "voice_primary_action": "Create receptionist",
        "voice_help_text": None,
    }


def _effective_whatsapp_status(wa: dict[str, Any]) -> str:
    """
    Do not present pending unless provider/Meta progression exists on the row.
    Otherwise callers would see in-flight remote setup when nothing has started.
    """
    st = (wa.get("status") or "not_connected").strip()
    if st != "pending":
        return st
    meta = (wa.get("meta_business_id") or "").strip()
    wnid = (wa.get("whatsapp_number_id") or "").strip()
    signup = (wa.get("telnyx_signup_id") or "").strip()
    if meta or wnid or signup:
        return "pending"
    return "needs_connection"


def compute_next_recommended_action(
    voice_status: str,
    sms_status: str,
    whatsapp_status: str,
) -> NextRecommendedAction:
    if voice_status == "failed":
        return "create_receptionist"
    if voice_status == "not_started":
        return "create_receptionist"
    if voice_status == "provisioning":
        return "check_voice"
    if sms_status == "failed":
        return "retry_sms"
    if whatsapp_status == "failed":
        return "retry_whatsapp"
    if sms_status == "not_started":
        return "activate_sms"
    if sms_status == "needs_submission":
        return "submit_sms"
    if sms_status == "pending_review":
        return "check_sms"
    if whatsapp_status == "not_connected":
        return "connect_whatsapp"
    if whatsapp_status == "needs_connection":
        return "continue_whatsapp"
    if whatsapp_status == "pending":
        return "check_whatsapp"
    return "none"


def _sms_guidance(status: str, failure_reason: str | None) -> dict[str, str | None]:
    fr = (failure_reason or "").strip() or None
    if status == "not_started":
        return {
            "sms_setup_title": "Activate SMS",
            "sms_setup_description": (
                "SMS requires business registration before customers can text this number."
            ),
            "sms_primary_action": "Start SMS setup",
            "sms_help_text": "Carrier approval is required before SMS becomes active.",
        }
    if status == "needs_submission":
        return {
            "sms_setup_title": "Complete SMS registration",
            "sms_setup_description": (
                "Review and complete the business details, use case, and sample messages "
                "required for carrier approval."
            ),
            "sms_primary_action": "Review SMS details",
            "sms_help_text": "Approval usually takes 1–2 business days after submission.",
        }
    if status == "pending_review":
        return {
            "sms_setup_title": "SMS review in progress",
            "sms_setup_description": (
                "Your SMS registration has been submitted and is waiting for carrier approval."
            ),
            "sms_primary_action": "Refresh status",
            "sms_help_text": "You can still use voice while SMS approval is pending.",
        }
    if status == "approved":
        return {
            "sms_setup_title": "SMS active",
            "sms_setup_description": "SMS is approved and ready on this business line.",
            "sms_primary_action": "",
            "sms_help_text": None,
        }
    if status == "failed":
        return {
            "sms_setup_title": "SMS setup needs attention",
            "sms_setup_description": (
                "Your SMS registration was rejected or needs changes before approval."
            ),
            "sms_primary_action": "Fix SMS setup",
            "sms_help_text": fr,
        }
    return {
        "sms_setup_title": "SMS",
        "sms_setup_description": None,
        "sms_primary_action": "",
        "sms_help_text": None,
    }


def _wa_guidance(status: str, failure_reason: str | None) -> dict[str, str | None]:
    fr = (failure_reason or "").strip() or None
    if status == "not_connected":
        return {
            "whatsapp_setup_title": "Connect WhatsApp",
            "whatsapp_setup_description": (
                "Connect your business number to WhatsApp through Meta and Telnyx."
            ),
            "whatsapp_primary_action": "Start WhatsApp setup",
            "whatsapp_help_text": "You will need to complete Meta / provider connection steps.",
        }
    if status == "needs_connection":
        return {
            "whatsapp_setup_title": "Continue WhatsApp setup",
            "whatsapp_setup_description": (
                "Finish the Meta / Telnyx connection flow to activate WhatsApp on this business number."
            ),
            "whatsapp_primary_action": "Continue WhatsApp setup",
            "whatsapp_help_text": "Setup usually takes a few minutes once Meta access is ready.",
        }
    if status == "pending":
        return {
            "whatsapp_setup_title": "WhatsApp setup in progress",
            "whatsapp_setup_description": (
                "We're waiting for Meta or your provider to finish connecting this number."
            ),
            "whatsapp_primary_action": "Check status",
            "whatsapp_help_text": "If this takes too long, retry or contact support.",
        }
    if status == "active":
        return {
            "whatsapp_setup_title": "WhatsApp active",
            "whatsapp_setup_description": "WhatsApp is connected and ready on this business line.",
            "whatsapp_primary_action": "",
            "whatsapp_help_text": None,
        }
    if status == "failed":
        return {
            "whatsapp_setup_title": "WhatsApp setup needs attention",
            "whatsapp_setup_description": "The WhatsApp connection did not complete successfully.",
            "whatsapp_primary_action": "Retry WhatsApp setup",
            "whatsapp_help_text": fr,
        }
    return {
        "whatsapp_setup_title": "WhatsApp",
        "whatsapp_setup_description": None,
        "whatsapp_primary_action": "",
        "whatsapp_help_text": None,
    }


def _sms_journey(sms: dict[str, Any], sms_status: str) -> dict[str, str | None]:
    brand_st = (sms.get("provider_brand_status") or "").strip() or None
    camp_st = (sms.get("provider_campaign_status") or "").strip() or None
    if sms_status == "not_started":
        return {
            "sms_user_action_summary": "Tap Start SMS setup when you are ready to register this line for texting.",
            "sms_echo_desk_automation_summary": "Nothing sent to the carrier yet.",
            "sms_provider_waiting_summary": None,
        }
    if sms_status == "needs_submission":
        return {
            "sms_user_action_summary": (
                "Confirm business and message samples (via API/PATCH registration or defaults we prefilled), "
                "then submit. Ensure TELNYX_MESSAGING_PROFILE_ID is configured on the server."
            ),
            "sms_echo_desk_automation_summary": (
                "After you submit, EchoDesk will call Telnyx: create 10DLC brand (if needed), submit campaign, "
                "and link this business number to the campaign."
            ),
            "sms_provider_waiting_summary": "Waiting on you to submit — not yet sent to Telnyx/TCR.",
        }
    if sms_status == "pending_review":
        return {
            "sms_user_action_summary": "Refresh this screen occasionally for status updates.",
            "sms_echo_desk_automation_summary": (
                "EchoDesk has submitted your brand/campaign to Telnyx. "
                + (f"Last brand status from provider: {brand_st}. " if brand_st else "")
                + (f"Last campaign status: {camp_st}. " if camp_st else "")
            ).strip(),
            "sms_provider_waiting_summary": "Waiting on The Campaign Registry / carriers to approve or reject the registration.",
        }
    if sms_status == "approved":
        return {
            "sms_user_action_summary": None,
            "sms_echo_desk_automation_summary": "SMS is approved for this line with your provider.",
            "sms_provider_waiting_summary": None,
        }
    if sms_status == "failed":
        return {
            "sms_user_action_summary": "Fix the issues noted, update registration if needed, then retry.",
            "sms_echo_desk_automation_summary": "Last submission failed at Telnyx/TCR — see error above.",
            "sms_provider_waiting_summary": None,
        }
    return {
        "sms_user_action_summary": None,
        "sms_echo_desk_automation_summary": None,
        "sms_provider_waiting_summary": None,
    }


def _wa_journey(wa: dict[str, Any], wa_status: str) -> dict[str, str | None]:
    handoff = (wa.get("embedded_oauth_url") or "").strip() or None
    prov_state = (wa.get("signup_state") or "").strip() or None
    if wa_status == "not_connected":
        return {
            "whatsapp_user_action_summary": "Tap Start WhatsApp setup to get a Telnyx/Meta handoff link.",
            "whatsapp_echo_desk_automation_summary": "EchoDesk will request a signup session from Telnyx when available, or open the Telnyx portal path.",
            "whatsapp_provider_waiting_summary": None,
            "whatsapp_handoff_url": None,
        }
    if wa_status == "needs_connection":
        return {
            "whatsapp_user_action_summary": (
                "Open the handoff link, sign in with Meta, and complete Telnyx embedded signup for this number."
            ),
            "whatsapp_echo_desk_automation_summary": (
                "EchoDesk stores your signup session id (if returned) and polls Telnyx for WhatsApp number status."
            ),
            "whatsapp_provider_waiting_summary": (
                f"Provider signup state: {prov_state}. " if prov_state else ""
            )
            + "Finish Meta/Telnyx steps in the browser.",
            "whatsapp_handoff_url": handoff,
        }
    if wa_status == "pending":
        return {
            "whatsapp_user_action_summary": "Use Check status / refresh after you progress in Meta or Telnyx.",
            "whatsapp_echo_desk_automation_summary": "EchoDesk polls Telnyx signup status and the WhatsApp phone list for this E.164.",
            "whatsapp_provider_waiting_summary": "Waiting on Meta or Telnyx to finish linking or verifying the number."
            + (f" Last state: {prov_state}." if prov_state else ""),
            "whatsapp_handoff_url": handoff,
        }
    if wa_status == "active":
        return {
            "whatsapp_user_action_summary": None,
            "whatsapp_echo_desk_automation_summary": "WhatsApp is linked on this business number per Telnyx.",
            "whatsapp_provider_waiting_summary": None,
            "whatsapp_handoff_url": None,
        }
    if wa_status == "failed":
        return {
            "whatsapp_user_action_summary": "Retry setup after resolving the error.",
            "whatsapp_echo_desk_automation_summary": None,
            "whatsapp_provider_waiting_summary": None,
            "whatsapp_handoff_url": None,
        }
    return {
        "whatsapp_user_action_summary": None,
        "whatsapp_echo_desk_automation_summary": None,
        "whatsapp_provider_waiting_summary": None,
        "whatsapp_handoff_url": None,
    }


def build_setup_summary(
    business: dict[str, Any],
    phone: dict[str, Any] | None,
    sms: dict[str, Any] | None,
    wa: dict[str, Any] | None,
    *,
    is_default_business: bool,
    primary_receptionist_name: str | None = None,
) -> dict[str, Any]:
    phone = phone or {}
    sms = sms or {"status": "not_started", "failure_reason": None}
    wa_raw = wa or {"status": "not_connected", "failure_reason": None}

    e164 = (phone.get("phone_number_e164") or "").strip() or None
    voice_status = _effective_voice_status(phone, e164)

    sms_status = (sms.get("status") or "not_started").strip()
    wa_status = _effective_whatsapp_status(wa_raw)

    next_action = compute_next_recommended_action(voice_status, sms_status, wa_status)
    voice_g = _voice_guidance(voice_status)
    sms_g = _sms_guidance(sms_status, sms.get("failure_reason"))
    wa_g = _wa_guidance(wa_status, wa_raw.get("failure_reason"))
    sms_j = _sms_journey(sms, sms_status)
    wa_j = _wa_journey(wa_raw, wa_status)

    return {
        "business_id": business.get("id"),
        "business_name": business.get("name"),
        "is_default_business": is_default_business,
        "mode": business.get("mode"),
        "primary_receptionist_name": primary_receptionist_name,
        "phone_number_e164": e164,
        "telnyx_number_id": phone.get("telnyx_number_id"),
        "voice_status": voice_status,
        **voice_g,
        "sms_status": sms_status,
        "sms_failure_reason": sms.get("failure_reason"),
        "sms_brand_id": sms.get("brand_id"),
        "sms_campaign_id": sms.get("campaign_id"),
        "sms_provider_brand_status": sms.get("provider_brand_status"),
        "sms_provider_campaign_status": sms.get("provider_campaign_status"),
        "whatsapp_status": wa_status,
        "whatsapp_failure_reason": wa_raw.get("failure_reason"),
        "whatsapp_signup_id": wa_raw.get("telnyx_signup_id"),
        "next_recommended_action": next_action,
        **sms_g,
        **wa_g,
        **sms_j,
        **wa_j,
    }
