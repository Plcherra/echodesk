"""
Send FCM push notifications for incoming/ended calls.
Fetches tokens from Supabase user_push_tokens and sends via firebase-admin.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from config import settings
from supabase_client import create_service_role_client

logger = logging.getLogger(__name__)

_firebase_app = None


def _get_messaging():
    """Initialize Firebase and return messaging instance."""
    global _firebase_app
    key_json = (settings.firebase_service_account_key or "").strip()
    if not key_json:
        return None
    try:
        if _firebase_app is None:
            import firebase_admin
            from firebase_admin import credentials
            cred_dict = json.loads(key_json)
            cred = credentials.Certificate(cred_dict)
            _firebase_app = firebase_admin.initialize_app(cred)
        from firebase_admin import messaging
        return messaging
    except Exception as e:
        logger.warning("Firebase init failed: %s", e)
        return None


def send_incoming_call_push(
    user_id: str,
    call_sid: str,
    caller: str,
    receptionist_id: str,
    receptionist_name: str = "Receptionist",
    call_log_id: str = "",
) -> int:
    """
    Send a normal FCM alert for a new call. The AI answers server-side;
    the notification opens that call's detail screen and does not offer
    Accept/Decline. Returns the number of messages sent successfully.
    """
    messaging = _get_messaging()
    if not messaging:
        logger.warning("FCM not configured (FIREBASE_SERVICE_ACCOUNT_KEY)")
        return 0

    supabase = create_service_role_client()
    res = supabase.table("user_push_tokens").select("token").eq("user_id", user_id).execute()
    tokens = [r["token"] for r in (res.data or []) if r.get("token")]
    if not tokens:
        logger.info("No push tokens for user %s", user_id)
        return 0

    display_name = (receptionist_name or "").strip() or "your receptionist"
    log_id = (call_log_id or "").strip()
    receptionist = (receptionist_id or "").strip()
    if receptionist and log_id:
        deep_link = f"/receptionists/{receptionist}/calls/{log_id}"
    elif receptionist:
        deep_link = f"/receptionists/{receptionist}/calls"
    else:
        deep_link = ""
    data = {
        "type": "incoming_call",
        "call_sid": call_sid,
        "caller": caller or "",
        "receptionist_id": receptionist,
        "receptionist_name": display_name,
        "call_log_id": log_id,
        "deep_link": deep_link,
    }
    # Ensure all values are strings for FCM data payload
    data = {k: str(v) for k, v in data.items()}

    # Title is what iOS shows when the app is not in the foreground.
    # There is no Accept action: the owner cannot join the call.
    title = f"New call to {display_name}"
    message = messaging.MulticastMessage(
        tokens=tokens,
        notification=messaging.Notification(
            title=title,
            body="Your AI receptionist is answering.",
        ),
        data=data,
        android=messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(channel_id="echodesk_calls"),
        ),
        apns=messaging.APNSConfig(
            payload=messaging.APNSPayload(aps=messaging.Aps(sound="default")),
        ),
    )

    try:
        result = messaging.send_each_for_multicast(message)
        logger.info("FCM incoming_call sent: %d/%d", result.success_count, len(tokens))
        return result.success_count
    except Exception as e:
        logger.error("FCM send failed: %s", e)
        return 0


def send_call_ended_push(
    user_id: str,
    call_sid: str,
    receptionist_id: str,
    receptionist_name: str = "Receptionist",
) -> int:
    """
    Send an informational FCM push when a call ends.
    Does not ask the device to hang up; the AI already owns the call.
    """
    messaging = _get_messaging()
    if not messaging:
        return 0

    supabase = create_service_role_client()
    res = supabase.table("user_push_tokens").select("token").eq("user_id", user_id).execute()
    tokens = [r["token"] for r in (res.data or []) if r.get("token")]
    if not tokens:
        return 0

    data = {
        "type": "call_ended",
        "call_sid": call_sid,
        "receptionist_id": receptionist_id or "",
        "receptionist_name": receptionist_name or "Receptionist",
    }
    data = {k: str(v) for k, v in data.items()}

    message = messaging.MulticastMessage(
        tokens=tokens,
        notification=messaging.Notification(
            title="Call ended",
            body=f"Call with {receptionist_name} ended",
        ),
        data=data,
        android=messaging.AndroidConfig(priority="high"),
        apns=messaging.APNSConfig(
            payload=messaging.APNSPayload(aps=messaging.Aps(content_available=True)),
        ),
    )

    try:
        result = messaging.send_each_for_multicast(message)
        return result.success_count
    except Exception as e:
        logger.error("FCM call_ended send failed: %s", e)
        return 0


def send_appointment_created_push(
    user_id: str,
    appointment_id: str,
    *,
    status: str = "needs_review",
    service_name: str | None = None,
    start_time: str | None = None,
) -> int:
    """
    Notify the owner that a new appointment was booked.
    Deep-link payload opens Needs Review (or appointment detail).
    """
    messaging = _get_messaging()
    if not messaging:
        logger.warning("FCM not configured (FIREBASE_SERVICE_ACCOUNT_KEY)")
        return 0

    supabase = create_service_role_client()
    res = supabase.table("user_push_tokens").select("token").eq("user_id", user_id).execute()
    tokens = [r["token"] for r in (res.data or []) if r.get("token")]
    if not tokens:
        logger.info("No push tokens for user %s", user_id)
        return 0

    label = (service_name or "").strip() or "Appointment"
    body = f"{label} needs your review" if status == "needs_review" else f"{label} booked"
    if start_time:
        body = f"{body} · {start_time}"

    data = {
        "type": "appointment_created",
        "appointment_id": appointment_id or "",
        "status": status or "needs_review",
        "deep_link": "/appointments?status=needs_review"
        if status == "needs_review"
        else (f"/appointments/{appointment_id}" if appointment_id else "/appointments"),
    }
    data = {k: str(v) for k, v in data.items()}

    message = messaging.MulticastMessage(
        tokens=tokens,
        notification=messaging.Notification(
            title="New appointment",
            body=body,
        ),
        data=data,
        android=messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(channel_id="echodesk_appointments"),
        ),
        apns=messaging.APNSConfig(
            payload=messaging.APNSPayload(aps=messaging.Aps(sound="default")),
        ),
    )

    try:
        result = messaging.send_each_for_multicast(message)
        logger.info(
            "FCM appointment_created sent: %d/%d appointment_id=%s",
            result.success_count,
            len(tokens),
            appointment_id,
        )
        return result.success_count
    except Exception as e:
        logger.error("FCM appointment_created send failed: %s", e)
        return 0
