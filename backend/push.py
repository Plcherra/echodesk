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
) -> int:
    """
    Send FCM push for incoming call. Fetches tokens from Supabase.
    Returns number of messages sent successfully.
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

    data = {
        "type": "incoming_call",
        "call_sid": call_sid,
        "caller": caller or "",
        "receptionist_id": receptionist_id or "",
        "receptionist_name": receptionist_name or "Receptionist",
    }
    # Ensure all values are strings for FCM data payload
    data = {k: str(v) for k, v in data.items()}

    message = messaging.MulticastMessage(
        tokens=tokens,
        notification=messaging.Notification(
            title="Incoming call",
            body=f"{receptionist_name} – Call from {caller or 'Unknown'}",
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
    Send FCM push when call ends (to clear CallKit UI).
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
