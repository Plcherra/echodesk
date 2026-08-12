"""Inbound SMS booking: simple idle / pending_confirm flow → scheduling engine → Telnyx reply."""

from __future__ import annotations

import logging
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from calendar_api.calendar_handler import (
    BUSINESS_DAY_END_HOUR,
    BUSINESS_DAY_START_HOUR,
    DEFAULT_AVAILABILITY_SLOT_MINUTES,
    DEFAULT_SLOT_MINUTES,
    DEFAULT_TIMEZONE,
    SUGGESTED_SLOTS_MAX,
    _check_service_first_guard,
    _load_closed_dates,
    load_scheduling_context_for_receptionist,
)
from scheduling import check_availability, create_booking
from supabase_client import create_service_role_client
from telnyx import sms as telnyx_sms
from telnyx.sms_customer_identity import apply_sms_template_vars, fetch_customer_sms_display_name
from telnyx.sms_webhook import store_sms_sent
from utils.phone import normalize_to_e164

logger = logging.getLogger(__name__)

_SMS_HELP_TEMPLATE = (
    "{business_name}: Message frequency varies. For help, contact the business directly. "
    "Message and data rates may apply. Reply STOP to opt out."
)
_SMS_STOP_CONFIRM_TEMPLATE = (
    "You have unsubscribed from messages from {business_name}. "
    "You will not receive further texts unless you contact the business again."
)
_GLOBAL_STOP_TOKENS = frozenset({"stop", "stopall", "unsubscribe", "end", "quit"})

_STATE_IDLE = "idle"
_STATE_PENDING = "pending_confirm"

_CONFIRM_TOKENS = frozenset(
    {
        "yes",
        "y",
        "yeah",
        "yep",
        "sure",
        "ok",
        "okay",
        "confirm",
        "book it",
        "lock it in",
        "yes please",
    }
)
_REJECT_TOKENS = frozenset({"no", "n", "nope", "cancel", "nah"})


def _friendly_time_label(iso_str: str, tz_name: str) -> str:
    """Portable, conversational local time (e.g. tomorrow at 3:00 PM)."""
    raw = (iso_str or "").strip()
    if not raw:
        return "that time"
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return "that time"
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=ZoneInfo("UTC"))
    z = ZoneInfo(tz_name)
    local = dt.astimezone(z)
    now = datetime.now(z)
    local_date = local.date()
    today = now.date()
    tomorrow = today + timedelta(days=1)
    h12 = local.hour % 12 or 12
    ampm = "AM" if local.hour < 12 else "PM"
    tpart = f"{h12}:{local.minute:02d} {ampm}"
    if local_date == tomorrow:
        return f"tomorrow at {tpart}"
    if local_date == today:
        return f"today at {tpart}"
    return f"{local.strftime('%a %b')} {local.day} at {tpart}"


def _is_confirm_message(text: str) -> bool:
    t = (text or "").strip().lower()
    if not t or len(t) > 32:
        return False
    return t in _CONFIRM_TOKENS


def _is_reject_message(text: str) -> bool:
    t = (text or "").strip().lower()
    if not t or len(t) > 24:
        return False
    return t in _REJECT_TOKENS


def _is_global_help(text: str) -> bool:
    t = (text or "").strip().lower()
    return t in ("help", "info")


def _is_global_stop(text: str) -> bool:
    t = (text or "").strip().lower()
    return t in _GLOBAL_STOP_TOKENS


def _sms_params_base(*, date_text: str) -> dict:
    """SMS v1: always generic appointment (no service pick over text)."""
    return {
        "date_text": date_text,
        "timezone": DEFAULT_TIMEZONE,
        "generic_appointment_requested": True,
        "duration_minutes": DEFAULT_SLOT_MINUTES,
    }


def _send_reply(*, to_number: str, from_number: str, text: str, supabase) -> None:
    text = (text or "").strip()
    if not text:
        return
    res = telnyx_sms.send_sms(to_number=to_number, from_number=from_number, text=text)
    if res.get("success"):
        mid = (res.get("telnyx_message_id") or "").strip() or None
        if mid:
            store_sms_sent(supabase=supabase, telnyx_message_id=mid, appointment_id=None, to_number=to_number)
    else:
        logger.warning(
            "[SMS_BOOK] send_failed to=%s error=%s",
            to_number[:6] + "…",
            res.get("error"),
        )


def _load_session(supabase, receptionist_id: str, customer_phone: str) -> dict | None:
    r = (
        supabase.table("sms_booking_sessions")
        .select("state, proposed_start_iso, duration_minutes")
        .eq("receptionist_id", receptionist_id)
        .eq("customer_phone", customer_phone)
        .limit(1)
        .execute()
    )
    rows = r.data or []
    return rows[0] if rows else None


def _upsert_session(
    supabase,
    *,
    receptionist_id: str,
    customer_phone: str,
    state: str,
    proposed_start_iso: str | None,
    duration_minutes: int,
) -> None:
    now_iso = datetime.utcnow().isoformat() + "Z"
    row = {
        "receptionist_id": receptionist_id,
        "customer_phone": customer_phone,
        "state": state,
        "proposed_start_iso": proposed_start_iso,
        "duration_minutes": duration_minutes,
        "updated_at": now_iso,
    }
    supabase.table("sms_booking_sessions").upsert(row, on_conflict="receptionist_id,customer_phone").execute()


def _reset_session_idle(supabase, receptionist_id: str, customer_phone: str) -> None:
    _upsert_session(
        supabase,
        receptionist_id=receptionist_id,
        customer_phone=customer_phone,
        state=_STATE_IDLE,
        proposed_start_iso=None,
        duration_minutes=DEFAULT_SLOT_MINUTES,
    )


def handle_incoming_message(
    *,
    customer_phone: str,
    message_text: str,
    receptionist_id: str,
    business_did: str,
    telnyx_event_id: str | None = None,
) -> None:
    """
    Core handler: intent → scheduling engine → session → SMS reply.
    """
    msg = (message_text or "").strip()
    if not msg:
        return

    customer_e164 = normalize_to_e164(customer_phone) or (customer_phone or "").strip()
    if not customer_e164:
        logger.warning("[SMS_BOOK] could not normalize customer phone")
        return

    if telnyx_event_id:
        supabase0 = create_service_role_client()
        try:
            dup = (
                supabase0.table("sms_inbound_events")
                .select("telnyx_event_id")
                .eq("telnyx_event_id", telnyx_event_id)
                .limit(1)
                .execute()
            )
            if dup.data:
                logger.info("[SMS_BOOK] duplicate inbound event skipped id=%s", telnyx_event_id[:24])
                return
            supabase0.table("sms_inbound_events").insert({"telnyx_event_id": telnyx_event_id}).execute()
        except Exception as e:
            logger.warning("[SMS_BOOK] idempotency failed (continuing): %s", e)

    supabase_early = create_service_role_client()
    display_name = fetch_customer_sms_display_name(supabase_early, receptionist_id)

    if _is_global_help(msg):
        _send_reply(
            to_number=customer_e164,
            from_number=business_did,
            text=apply_sms_template_vars(_SMS_HELP_TEMPLATE, display_name) or "",
            supabase=supabase_early,
        )
        return

    if _is_global_stop(msg):
        _reset_session_idle(supabase_early, receptionist_id, customer_e164)
        _send_reply(
            to_number=customer_e164,
            from_number=business_did,
            text=apply_sms_template_vars(_SMS_STOP_CONFIRM_TEMPLATE, display_name) or "",
            supabase=supabase_early,
        )
        return

    ctx = load_scheduling_context_for_receptionist(receptionist_id)
    if not ctx.get("ok"):
        _send_reply(
            to_number=customer_e164,
            from_number=business_did,
            text=f"{display_name}: Sorry — I can't reach the calendar right now. Try again soon or give us a call.",
            supabase=create_service_role_client(),
        )
        return

    service = ctx["service"]
    calendar_id = ctx["calendar_id"]
    supabase = ctx["supabase"]

    session = _load_session(supabase, receptionist_id, customer_e164) or {}
    state = (session.get("state") or _STATE_IDLE).strip()

    if state == _STATE_PENDING:
        if _is_confirm_message(msg):
            proposed = (session.get("proposed_start_iso") or "").strip()
            dur = int(session.get("duration_minutes") or DEFAULT_SLOT_MINUTES)
            if not proposed:
                _reset_session_idle(supabase, receptionist_id, customer_e164)
                _send_reply(
                    to_number=customer_e164,
                    from_number=business_did,
                    text="Something got out of sync — text me a time again and we'll set it up.",
                    supabase=supabase,
                )
                return
            book_params = {
                "start_time": proposed,
                "caller_phone": customer_e164,
                "summary": "Appointment (SMS)",
                "duration_minutes": dur,
                "timezone": DEFAULT_TIMEZONE,
                "generic_appointment_requested": True,
            }
            book_res = create_booking(
                service,
                calendar_id,
                book_params,
                receptionist_id,
                supabase,
                default_timezone=DEFAULT_TIMEZONE,
                default_slot_minutes=DEFAULT_SLOT_MINUTES,
                call_control_id=None,
                staff_id=None,
            )
            if book_res.get("success"):
                _reset_session_idle(supabase, receptionist_id, customer_e164)
                when = _friendly_time_label(proposed, DEFAULT_TIMEZONE)
                _send_reply(
                    to_number=customer_e164,
                    from_number=business_did,
                    text=f"You're all set for {when} with {display_name} \N{THUMBS UP SIGN}",
                    supabase=supabase,
                )
            else:
                _reset_session_idle(supabase, receptionist_id, customer_e164)
                err = (book_res.get("message") or "").strip()
                if book_res.get("error") == "slot_unavailable":
                    _send_reply(
                        to_number=customer_e164,
                        from_number=business_did,
                        text="That slot just got taken — text me another time and I'll check.",
                        supabase=supabase,
                    )
                else:
                    _send_reply(
                        to_number=customer_e164,
                        from_number=business_did,
                        text=err or "Couldn't complete the booking. Try a different time?",
                        supabase=supabase,
                    )
            return

        if _is_reject_message(msg):
            _reset_session_idle(supabase, receptionist_id, customer_e164)
            _send_reply(
                to_number=customer_e164,
                from_number=business_did,
                text="No problem — text me whenever you want to try another time.",
                supabase=supabase,
            )
            return

        _send_reply(
            to_number=customer_e164,
            from_number=business_did,
            text="Reply YES to lock it in, or NO to cancel.",
            supabase=supabase,
        )
        return

    # --- idle: treat as booking request ---
    params = _sms_params_base(date_text=msg)
    guard = _check_service_first_guard(supabase, receptionist_id, params)
    if guard:
        _send_reply(
            to_number=customer_e164,
            from_number=business_did,
            text=(guard.get("message") or "What time works for you?"),
            supabase=supabase,
        )
        return

    avail = check_availability(
        service,
        calendar_id,
        params,
        default_timezone=DEFAULT_TIMEZONE,
        default_slot_minutes=DEFAULT_SLOT_MINUTES,
        default_availability_slot_minutes=DEFAULT_AVAILABILITY_SLOT_MINUTES,
        business_day_start_hour=BUSINESS_DAY_START_HOUR,
        business_day_end_hour=BUSINESS_DAY_END_HOUR,
        suggested_slots_max=SUGGESTED_SLOTS_MAX,
        staff_id=None,
        bookable_hours=(ctx.get("receptionist") or {}).get("bookable_hours"),
        closed_dates=_load_closed_dates(supabase, receptionist_id),
    )

    if not avail.get("success"):
        fail_msg = (avail.get("message") or "").strip()
        _send_reply(
            to_number=customer_e164,
            from_number=business_did,
            text=fail_msg
            or "Couldn't find that time. Try something like 'tomorrow at 2pm'.",
            supabase=supabase,
        )
        return

    dur = int(avail.get("slot_duration_minutes") or DEFAULT_SLOT_MINUTES)
    free_slots: list = list(avail.get("free_slots") or [])

    if avail.get("slot_available") and avail.get("requested_slot_start"):
        proposed_iso = avail["requested_slot_start"]
        when = _friendly_time_label(proposed_iso, DEFAULT_TIMEZONE)
        _upsert_session(
            supabase,
            receptionist_id=receptionist_id,
            customer_phone=customer_e164,
            state=_STATE_PENDING,
            proposed_start_iso=proposed_iso,
            duration_minutes=dur,
        )
        _send_reply(
            to_number=customer_e164,
            from_number=business_did,
            text=f"I got you at {when} with {display_name}. Want me to lock it in?",
            supabase=supabase,
        )
        return

    if free_slots:
        first = free_slots[0]
        when_a = _friendly_time_label(first, DEFAULT_TIMEZONE)
        _upsert_session(
            supabase,
            receptionist_id=receptionist_id,
            customer_phone=customer_e164,
            state=_STATE_PENDING,
            proposed_start_iso=first,
            duration_minutes=dur,
        )
        _send_reply(
            to_number=customer_e164,
            from_number=business_did,
            text=f"That time's taken — I can do {when_a} for {display_name} instead. Want me to lock it in?",
            supabase=supabase,
        )
        return

    _send_reply(
        to_number=customer_e164,
        from_number=business_did,
        text="Couldn't find an open slot then. Try another day or time?",
        supabase=supabase,
    )


def handle_inbound_telnyx_message(*, data: dict) -> None:
    """Parse Telnyx message.received envelope and dispatch to handle_incoming_message."""
    event_id = (data.get("id") or "").strip() or None
    payload = data.get("payload") or {}
    if not isinstance(payload, dict):
        return

    direction = (payload.get("direction") or "").strip().lower()
    if direction and direction != "inbound":
        return

    text = (payload.get("text") or payload.get("body") or "").strip()
    if not text:
        return

    from_obj = payload.get("from") or {}
    if isinstance(from_obj, dict):
        from_raw = (from_obj.get("phone_number") or "").strip()
    else:
        from_raw = str(from_obj or "").strip()

    to_list = payload.get("to") or []
    to_raw = ""
    if to_list and isinstance(to_list[0], dict):
        to_raw = (to_list[0].get("phone_number") or "").strip()

    if not from_raw or not to_raw:
        logger.warning("[SMS_INBOUND] missing from/to")
        return

    supabase = create_service_role_client()
    from telnyx.receptionist_lookup import get_receptionist_by_did

    rec = get_receptionist_by_did(supabase, to_raw, direction="inbound")
    if not rec:
        logger.info("[SMS_INBOUND] no receptionist for DID %s", to_raw[:8])
        return

    receptionist_id = rec.get("id")
    if not receptionist_id:
        return

    handle_incoming_message(
        customer_phone=from_raw,
        message_text=text,
        receptionist_id=receptionist_id,
        business_did=to_raw,
        telnyx_event_id=event_id,
    )
