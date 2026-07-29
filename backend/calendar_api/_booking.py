from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from ._parsing import get_free_slots, parse_iso_datetime_or_natural
from telnyx import sms as telnyx_sms
from telnyx.sms_customer_identity import apply_sms_template_vars, fetch_customer_sms_display_name
from telnyx.sms_delivery_registry import is_us_toll_free_e164

logger = logging.getLogger(__name__)


def _ensure_aware_wall_time(dt: datetime, timezone: str) -> datetime:
    """Attach IANA zone to naive datetimes so Google Calendar freeBusy gets RFC3339 offsets."""
    if dt.tzinfo is not None:
        return dt
    return dt.replace(tzinfo=ZoneInfo(timezone))


_SERVICE_SELECT_FIELDS = (
    "id, name, duration_minutes, price_cents, requires_location, default_location_type, "
    "followup_mode, followup_message_template, payment_link, meeting_instructions, "
    "owner_selected_platform, internal_followup_notes"
)

_RECEPTIONIST_SELECT_FIELDS = "id, generic_followup_message_template"

_DEFAULT_GENERIC_UNDER_REVIEW_MESSAGE = (
    "Your appointment with {business_name} is under review and additional information will be provided soon."
)
_DEFAULT_PAYMENT_FOLLOWUP_MESSAGE = (
    "We'll text you a payment link shortly to confirm your appointment with {business_name}."
)

_SMS_OPTOUT_SUFFIX = "Reply STOP to opt out."
_E164_RE = re.compile(r"^\+\d{10,15}$")


def _mask_phone(p: str | None) -> str:
    s = (p or "").strip()
    if not s:
        return "(empty)"
    # Keep country code + last 2 digits when possible
    digits = "".join(ch for ch in s if ch.isdigit())
    if len(digits) <= 4:
        return "***"
    return f"{digits[:2]}***{digits[-2:]}"


def _resolve_sms_from_number(*, supabase, receptionist_id: str) -> str | None:
    if not supabase or not receptionist_id:
        return None
    try:
        res = (
            supabase.table("receptionists")
            .select("id, telnyx_phone_number, inbound_phone_number")
            .eq("id", receptionist_id)
            .limit(1)
            .execute()
        )
        if res and getattr(res, "data", None):
            row = res.data[0] or {}
            from_num = (row.get("telnyx_phone_number") or "").strip() or None
            if from_num:
                return from_num
            from_num = (row.get("inbound_phone_number") or "").strip() or None
            return from_num
        return None
    except Exception:
        logger.exception("[CAL_BOOK] sms_from_number_resolve_failed receptionist_id=%s", receptionist_id)
        return None


def _normalize_service_name(s: str | None) -> str:
    """Normalize for matching: lowercase, trim, collapse spaces, remove simple punctuation."""
    if not s or not isinstance(s, str):
        return ""
    s = s.strip().lower()
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r"[.,;:!?\-'\"()]", "", s)
    return s.strip()


# ASR-friendly: map common spoken variants to shared stem for matching
_SERVICE_WORD_STEMS = {
    "consultation": "consult",
    "consultations": "consult",
    "consulting": "consult",
    "consultant": "consult",
    "consultants": "consult",
}


def _stem_service_word(w: str) -> str:
    """Map common ASR variants (consultation, consulting, consultant) to shared stem."""
    if not w or not isinstance(w, str):
        return ""
    w = w.strip().lower()
    return _SERVICE_WORD_STEMS.get(w, w)


def _stemmed_service_name(s: str) -> str:
    """Apply word-level stemming for ASR-tolerant matching."""
    if not s or not isinstance(s, str):
        return ""
    norm = _normalize_service_name(s)
    words = norm.split()
    stemmed = " ".join(_stem_service_word(w) for w in words if w)
    return stemmed.strip()


def _normalize_phone(phone: str | None) -> str | None:
    """Normalize for E.164: trim whitespace; if already valid E.164, pass through.
    Otherwise remove spaces/parens/dashes/dots and ensure + prefix for 10-15 digit numbers.
    Handles URL-decoded numbers where + became space (e.g. 16176537747 -> +16176537747).
    For 10-digit numbers starting with 2-9, assume US and prepend +1."""
    if not phone or not isinstance(phone, str):
        return None
    s = phone.strip()
    if not s:
        return None
    # Already valid E.164? Pass through unchanged (only trim)
    if _E164_RE.match(s):
        return s
    digits = "".join(c for c in s if c.isdigit())
    if not digits or len(digits) < 10:
        return None
    if len(digits) > 15:
        return None
    # 10 digits starting with 2-9: assume US, prepend +1
    if len(digits) == 10 and digits[0] in "23456789":
        return "+1" + digits
    # 11-15 digits: prepend + (handles 16176537747 -> +16176537747)
    return "+" + digits


def _is_e164(phone: str | None) -> bool:
    s = (phone or "").strip()
    return bool(s and _E164_RE.match(s))


def _resolve_generic_followup_template(*, supabase, receptionist_id: str) -> str | None:
    if not supabase or not receptionist_id:
        return None
    try:
        res = (
            supabase.table("receptionists")
            .select(_RECEPTIONIST_SELECT_FIELDS)
            .eq("id", receptionist_id)
            .limit(1)
            .execute()
        )
        if res and getattr(res, "data", None):
            tmpl = (res.data[0].get("generic_followup_message_template") or "").strip()
            return tmpl or None
        return None
    except Exception:
        logger.exception(
            "[CAL_BOOK] generic_followup_template_resolve_failed receptionist_id=%s",
            receptionist_id,
        )
        return None


def _resolve_followup_for_booking(
    *,
    service_based: bool,
    resolved_service: dict | None,
    supabase,
    receptionist_id: str,
) -> dict:
    """
    Returns resolved follow-up fields to persist and return to caller:
    - booking_mode, followup_mode, followup_message_resolved, payment_link,
      meeting_instructions, owner_selected_platform, internal_followup_notes
    """
    display_name = fetch_customer_sms_display_name(supabase, receptionist_id)

    if service_based and isinstance(resolved_service, dict):
        booking_mode = "service_based"
        followup_mode = (resolved_service.get("followup_mode") or "").strip() or "under_review"
        template = (resolved_service.get("followup_message_template") or "").strip() or None
        payment_link = (resolved_service.get("payment_link") or "").strip() or None
        meeting_instructions = (resolved_service.get("meeting_instructions") or "").strip() or None
        owner_selected_platform = (resolved_service.get("owner_selected_platform") or "").strip() or None
        internal_followup_notes = (resolved_service.get("internal_followup_notes") or "").strip() or None

        if followup_mode == "send_custom_message":
            msg = template
        elif followup_mode == "send_payment_link":
            msg = template or _DEFAULT_PAYMENT_FOLLOWUP_MESSAGE
        elif followup_mode == "under_review":
            msg = template or _DEFAULT_GENERIC_UNDER_REVIEW_MESSAGE
        else:
            # none or unknown -> treat as none
            followup_mode = "none"
            msg = None

        if msg:
            msg = apply_sms_template_vars(msg, display_name)

        return {
            "booking_mode": booking_mode,
            "followup_mode": followup_mode,
            "followup_message_resolved": msg,
            "payment_link": payment_link,
            "meeting_instructions": meeting_instructions,
            "owner_selected_platform": owner_selected_platform,
            "internal_followup_notes": internal_followup_notes,
            "template_source": "service_template" if template else "service_default",
        }

    # Generic/no-service booking: always under review
    booking_mode = "generic"
    tmpl = _resolve_generic_followup_template(supabase=supabase, receptionist_id=receptionist_id)
    msg = tmpl or _DEFAULT_GENERIC_UNDER_REVIEW_MESSAGE
    if msg:
        msg = apply_sms_template_vars(msg, display_name)
    return {
        "booking_mode": booking_mode,
        "followup_mode": "under_review",
        "followup_message_resolved": msg,
        "payment_link": None,
        "meeting_instructions": None,
        "owner_selected_platform": None,
        "internal_followup_notes": None,
        "template_source": "receptionist_generic" if tmpl else "backend_fallback",
    }


def _resolve_service_for_booking(
    *,
    supabase,
    receptionist_id: str,
    service_id,
    service_name: str | None,
) -> dict | None:
    if not supabase or not receptionist_id:
        return None
    if service_id is not None and not isinstance(service_id, str):
        service_id = str(service_id)
    service_id = (service_id or "").strip() or None
    service_name = (service_name or "").strip() or None
    if not service_id and not service_name:
        return None

    try:
        base = (
            supabase.table("services")
            .select(_SERVICE_SELECT_FIELDS)
            .eq("receptionist_id", receptionist_id)
        )
        if service_id:
            res = base.eq("id", service_id).limit(1).execute()
            if res and getattr(res, "data", None):
                return res.data[0]
            return None

        # Name-based resolution with normalization and safe matching order.
        incoming_raw = service_name
        incoming_norm = _normalize_service_name(service_name)
        if not incoming_norm:
            logger.info(
                "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=empty resolved_id=None resolved_name=None",
                incoming_raw,
                incoming_norm,
            )
            return None

        res = base.execute()
        all_services = (res.data or []) if res and getattr(res, "data", None) else []
        if not all_services:
            logger.info(
                "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=no_services resolved_id=None resolved_name=None",
                incoming_raw,
                incoming_norm,
            )
            return None

        # 1. Exact normalized match
        for svc in all_services:
            stored_name = (svc.get("name") or "").strip()
            stored_norm = _normalize_service_name(stored_name)
            if stored_norm == incoming_norm:
                logger.info(
                    "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=exact_normalized resolved_id=%s resolved_name=%r",
                    incoming_raw,
                    incoming_norm,
                    svc.get("id"),
                    stored_name,
                )
                return svc

        # 2. Case-insensitive exact (already covered by normalized; try direct ilike as fallback)
        for svc in all_services:
            stored_name = (svc.get("name") or "").strip()
            if stored_name and stored_name.lower() == incoming_norm:
                logger.info(
                    "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=exact_ci resolved_id=%s resolved_name=%r",
                    incoming_raw,
                    incoming_norm,
                    svc.get("id"),
                    stored_name,
                )
                return svc

        # 3. Contained-match only if unambiguous
        contained_matches = []
        for svc in all_services:
            stored_name = (svc.get("name") or "").strip()
            stored_norm = _normalize_service_name(stored_name)
            if not stored_norm:
                continue
            # Incoming contained in stored, or stored contained in incoming
            if incoming_norm in stored_norm or stored_norm in incoming_norm:
                contained_matches.append(svc)
        if len(contained_matches) == 1:
            svc = contained_matches[0]
            logger.info(
                "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=contained_unambiguous resolved_id=%s resolved_name=%r",
                incoming_raw,
                incoming_norm,
                svc.get("id"),
                (svc.get("name") or "").strip(),
            )
            return svc
        if len(contained_matches) > 1:
            logger.info(
                "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=contained_ambiguous count=%d resolved_id=None resolved_name=None",
                incoming_raw,
                incoming_norm,
                len(contained_matches),
            )
            return None

        # 4. Stem/variant match for ASR tolerance (consultation/consulting/consultant -> consult)
        incoming_stemmed = _stemmed_service_name(incoming_raw)
        if incoming_stemmed:
            stem_matches = []
            for svc in all_services:
                stored_name = (svc.get("name") or "").strip()
                stored_stemmed = _stemmed_service_name(stored_name)
                if not stored_stemmed:
                    continue
                if incoming_stemmed in stored_stemmed or stored_stemmed in incoming_stemmed:
                    stem_matches.append(svc)
            if len(stem_matches) == 1:
                svc = stem_matches[0]
                logger.info(
                    "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=stem_unambiguous resolved_id=%s resolved_name=%r",
                    incoming_raw,
                    incoming_norm,
                    svc.get("id"),
                    (svc.get("name") or "").strip(),
                )
                return svc
            if len(stem_matches) > 1:
                logger.info(
                    "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=stem_ambiguous count=%d resolved_id=None resolved_name=None",
                    incoming_raw,
                    incoming_norm,
                    len(stem_matches),
                )
                return None

        logger.info(
            "[CAL_BOOK] service_resolution incoming=%r normalized=%r match_mode=no_match resolved_id=None resolved_name=None",
            incoming_raw,
            incoming_norm,
        )
        return None
    except Exception:
        logger.exception(
            "[CAL_BOOK] service_resolve_failed receptionist_id=%s service_id=%s service_name=%r",
            receptionist_id,
            service_id,
            service_name,
        )
        return None


def handle_create_appointment(
    service,
    calendar_id: str,
    params: dict,
    *,
    receptionist_id: str,
    supabase,
    default_timezone: str,
    default_slot_minutes: int,
    call_control_id: str | None = None,
) -> dict:
    timezone = (params.get("timezone") or default_timezone).strip() or default_timezone
    start_time = params.get("start_time") or params.get("date_text")
    duration_minutes = params.get("duration_minutes") or default_slot_minutes
    summary = params.get("summary") or "Appointment"
    description = params.get("description")
    attendees = params.get("attendees")
    # Optional appointment / booking fields (provider-ready)
    location_type = (params.get("location_type") or "").strip() or None
    location_text = (params.get("location_text") or "").strip() or None
    customer_address = (params.get("customer_address") or "").strip() or None
    service_id = params.get("service_id")
    service_name = (params.get("service_name") or "").strip() or None
    notes = (params.get("notes") or "").strip() or None
    price_cents = params.get("price_cents")

    if isinstance(duration_minutes, str):
        try:
            duration_minutes = int(duration_minutes) or default_slot_minutes
        except (ValueError, TypeError):
            duration_minutes = default_slot_minutes
    if service_id is not None and isinstance(service_id, str) and not service_id.strip():
        service_id = None
    if price_cents is not None:
        try:
            price_cents = int(price_cents)
        except (TypeError, ValueError):
            price_cents = None

    resolved_service = _resolve_service_for_booking(
        supabase=supabase,
        receptionist_id=receptionist_id,
        service_id=service_id,
        service_name=service_name,
    )

    # Service-based booking: if the selected service maps to a stored service with duration > 0,
    # the stored service configuration is authoritative.
    service_based = False
    if isinstance(resolved_service, dict):
        try:
            svc_dur = int(resolved_service.get("duration_minutes") or 0)
        except (TypeError, ValueError):
            svc_dur = 0
        if svc_dur > 0:
            service_based = True

    if service_based:
        # Authoritative duration.
        duration_minutes = int(resolved_service.get("duration_minutes") or duration_minutes)

        # Prefer stored service name/id when present (for persistence consistency).
        service_id = resolved_service.get("id") or service_id
        service_name = (resolved_service.get("name") or service_name or "").strip() or service_name

        # Prefer stored price when set (do not invent).
        svc_price = resolved_service.get("price_cents")
        if svc_price is not None:
            try:
                svc_price_i = int(svc_price)
            except (TypeError, ValueError):
                svc_price_i = None
            if svc_price_i is not None and svc_price_i > 0:
                price_cents = svc_price_i

        # Authoritative location_type when configured.
        svc_loc_type = (resolved_service.get("default_location_type") or "").strip() or None
        if svc_loc_type:
            location_type = svc_loc_type

        # Enforce required details only when service requires a location.
        requires_location = bool(resolved_service.get("requires_location"))
        if requires_location:
            if location_type == "customer_address" and not customer_address:
                return {
                    "success": False,
                    "error": "location_missing",
                    "message": "What address should I use for the appointment?",
                }
            if location_type == "custom" and not location_text:
                return {
                    "success": False,
                    "error": "location_missing",
                    "message": "What details should I include for the appointment location?",
                }

    if not start_time:
        return {"success": False, "error": "date_missing", "message": "What day and time should I book it for?"}

    try:
        start_d = parse_iso_datetime_or_natural(start_time, timezone=timezone)
        if not start_d:
            return {"success": False, "error": "date_parse_failed", "message": "I couldn't understand the date/time. What day and time works for you?"}
        try:
            start_d = _ensure_aware_wall_time(start_d, timezone)
        except Exception:
            return {"success": False, "error": "date_parse_failed", "message": "I couldn't understand the date/time. What day and time works for you?"}
        end_d = start_d + timedelta(minutes=duration_minutes)
    except (ValueError, TypeError):
        return {"success": False, "error": "date_parse_failed", "message": "I couldn't understand the date/time. What day and time works for you?"}

    start_iso = start_d.isoformat()
    end_iso = end_d.isoformat()
    followup = _resolve_followup_for_booking(
        service_based=service_based,
        resolved_service=resolved_service if isinstance(resolved_service, dict) else None,
        supabase=supabase,
        receptionist_id=receptionist_id,
    )
    logger.info(
        "[CAL_BOOK] followup_resolution booking_mode=%s followup_mode=%s has_template=%s has_payment_link=%s has_message=%s",
        followup.get("booking_mode"),
        followup.get("followup_mode"),
        bool((resolved_service or {}).get("followup_message_template")) if service_based else False,
        bool(followup.get("payment_link")),
        bool(followup.get("followup_message_resolved")),
    )
    logger.info(
        "[CAL_BOOK] service_resolution mode=%s selected_service_id=%s selected_service_name=%r resolved=%s resolved_duration_minutes=%s resolved_price_cents=%s resolved_location_type=%s",
        "service_based" if service_based else "generic",
        params.get("service_id"),
        (params.get("service_name") or "").strip() or None,
        bool(resolved_service),
        duration_minutes,
        price_cents,
        location_type,
    )
    logger.info(
        "[CAL_BOOK] create_appointment calendar_id=%s start=%s end=%s duration_minutes=%s",
        calendar_id,
        start_iso,
        end_iso,
        duration_minutes,
    )

    # Build description: optional location line for calendar event
    desc_parts = []
    if description:
        desc_parts.append(description)
    location_display = customer_address or location_text
    if location_display and location_type:
        desc_parts.append(f"Location ({location_type}): {location_display}")
    elif location_display:
        desc_parts.append(f"Location: {location_display}")
    if notes:
        desc_parts.append(f"Notes: {notes}")
    event_description = "\n\n".join(desc_parts) if desc_parts else None

    # Check busy before insert
    freebusy_res = service.freebusy().query(
        body={
            "timeMin": start_iso,
            "timeMax": end_iso,
            "items": [{"id": calendar_id}],
        }
    ).execute()
    busy = freebusy_res.get("calendars", {}).get(calendar_id, {}).get("busy") or []

    if busy:
        day_start = start_d.replace(hour=0, minute=0, second=0, microsecond=0)
        day_end = day_start + timedelta(days=1)
        day_fb = service.freebusy().query(
            body={
                "timeMin": day_start.isoformat(),
                "timeMax": day_end.isoformat(),
                "items": [{"id": calendar_id}],
            }
        ).execute()
        day_busy = day_fb.get("calendars", {}).get(calendar_id, {}).get("busy") or []
        suggested = get_free_slots(
            busy=day_busy,
            time_min=day_start.isoformat(),
            time_max=day_end.isoformat(),
            slot_minutes=duration_minutes,
        )[:5]
        return {
            "success": False,
            "error": "slot_unavailable",
            "message": "That time slot is no longer available.",
            "suggested_slots": suggested,
        }

    event_body = {
        "summary": summary,
        "start": {"dateTime": start_iso, "timeZone": timezone},
        "end": {"dateTime": end_iso, "timeZone": timezone},
    }
    if event_description:
        event_body["description"] = event_description
    if attendees and isinstance(attendees, list):
        event_body["attendees"] = [{"email": e} for e in attendees if isinstance(e, str)]

    try:
        event = service.events().insert(
            calendarId=calendar_id,
            body=event_body,
            sendUpdates="none",
        ).execute()
    except Exception as e:
        msg = str(e)
        is_conflict = "Conflict" in msg or "409" in msg or "not found" in msg.lower() or "busy" in msg.lower()
        if is_conflict:
            day_start = start_d.replace(hour=0, minute=0, second=0, microsecond=0)
            day_end = day_start + timedelta(days=1)
            try:
                day_fb = service.freebusy().query(
                    body={
                        "timeMin": day_start.isoformat(),
                        "timeMax": day_end.isoformat(),
                        "items": [{"id": calendar_id}],
                    }
                ).execute()
                day_busy = day_fb.get("calendars", {}).get(calendar_id, {}).get("busy") or []
                suggested = get_free_slots(
                    busy=day_busy,
                    time_min=day_start.isoformat(),
                    time_max=day_end.isoformat(),
                    slot_minutes=duration_minutes,
                )[:5]
            except Exception:
                suggested = []
            logger.info(
                "[CAL_BOOK] create_appointment error type=slot_unavailable message=%s",
                msg[:200],
            )
            return {
                "success": False,
                "error": "slot_unavailable",
                "message": "That time slot is no longer available.",
                "suggested_slots": suggested,
            }
        logger.warning(
            "[CAL_BOOK] create_appointment error type=calendar_internal_error message=%s",
            msg[:200],
        )
        return {
            "success": False,
            "error": "calendar_internal_error",
            "message": "I had trouble creating the appointment, but the slot may still be available.",
        }

    logger.info("[CAL_BOOK] create_appointment success event_id=%s", event.get("id"))

    # Status: generic -> needs_review, service_based -> confirmed
    booking_mode = followup.get("booking_mode") or "generic"
    appointment_status = "needs_review" if booking_mode == "generic" else "confirmed"

    # Caller number (E.164) for appointment review UI
    to_number_raw = (params.get("caller_phone") or "").strip() or None
    caller_number = _normalize_phone(to_number_raw) if to_number_raw else None
    if caller_number and not _is_e164(caller_number):
        caller_number = None

    call_log_id = None
    if call_control_id:
        try:
            cl_res = (
                supabase.table("call_logs")
                .select("id")
                .eq("call_control_id", call_control_id)
                .limit(1)
                .execute()
            )
            if cl_res and cl_res.data and len(cl_res.data) > 0:
                call_log_id = cl_res.data[0].get("id")
        except Exception as ex:
            logger.debug("[CAL_BOOK] call_log_id lookup failed: %s", ex)

    appointment_id = None
    try:
        insert_data = {
            "receptionist_id": receptionist_id,
            "event_id": event.get("id"),
            "start_time": start_iso,
            "end_time": end_iso,
            "duration_minutes": duration_minutes,
            "summary": summary,
            "description": event_description,
            "service_id": service_id,
            "service_name": service_name,
            "location_type": location_type,
            "location_text": location_text,
            "customer_address": customer_address,
            "price_cents": price_cents,
            "notes": notes,
            "status": appointment_status,
            "caller_number": caller_number,
            "booking_mode": followup.get("booking_mode"),
            "followup_mode": followup.get("followup_mode"),
            "followup_message_resolved": followup.get("followup_message_resolved"),
            "payment_link": followup.get("payment_link"),
            "meeting_instructions": followup.get("meeting_instructions"),
            "owner_selected_platform": followup.get("owner_selected_platform"),
            "internal_followup_notes": followup.get("internal_followup_notes"),
            "updated_at": datetime.utcnow().isoformat() + "Z",
        }
        if call_log_id:
            insert_data["call_log_id"] = call_log_id
        ins_res = supabase.table("appointments").insert(insert_data).execute()
        if ins_res and getattr(ins_res, "data", None) and len(ins_res.data) > 0:
            appointment_id = ins_res.data[0].get("id")
            # Best-effort owner push (never breaks booking).
            if appointment_id and appointment_status == "needs_review":
                try:
                    owner_res = (
                        supabase.table("receptionists")
                        .select("user_id")
                        .eq("id", receptionist_id)
                        .limit(1)
                        .execute()
                    )
                    owner_id = None
                    if owner_res and owner_res.data:
                        owner_id = owner_res.data[0].get("user_id")
                    if owner_id:
                        from push import send_appointment_created_push

                        send_appointment_created_push(
                            owner_id,
                            str(appointment_id),
                            status=appointment_status,
                            service_name=service_name or summary,
                            start_time=start_iso,
                        )
                except Exception as push_ex:
                    logger.debug(
                        "[CAL_BOOK] appointment push skipped: %s", push_ex
                    )
    except Exception as ex:
        logger.warning("[CAL_BOOK] appointments insert failed (event already created): %s", ex)

    # Immediate post-booking SMS follow-up (best-effort; never breaks booking).
    sms_attempted = False
    sms_api_accepted = False
    sms_telnyx_message_id: str | None = None
    sms_from_for_telemetry: str | None = None
    try:
        to_number = caller_number
        from_number = _resolve_sms_from_number(supabase=supabase, receptionist_id=receptionist_id)
        sms_from_for_telemetry = from_number
        resolved_msg = (followup.get("followup_message_resolved") or "").strip() or None
        validation_ok = to_number is not None and _is_e164(to_number)

        logger.info(
            "[CAL_BOOK] sms_followup_diag raw_caller_phone=%r normalized=%r validation_e164=%s from_number=%s",
            to_number_raw,
            to_number,
            validation_ok,
            _mask_phone(from_number) if from_number else "(empty)",
        )

        if to_number_raw and not to_number:
            logger.info(
                "[CAL_BOOK] booking_created_no_followup_channel reason=normalize_failed raw=%r mode=%s",
                to_number_raw,
                followup.get("booking_mode"),
            )
        elif to_number and not _is_e164(to_number):
            logger.info(
                "[CAL_BOOK] booking_created_no_followup_channel reason=invalid_e164 normalized=%r mode=%s",
                to_number,
                followup.get("booking_mode"),
            )
        elif not from_number:
            logger.info(
                "[CAL_BOOK] booking_created_no_followup_channel reason=from_number_empty receptionist_id=%s",
                receptionist_id,
            )
        elif not resolved_msg:
            logger.info(
                "[CAL_BOOK] booking_created_no_followup_channel reason=no_followup_message mode=%s",
                followup.get("booking_mode"),
            )
        elif to_number and from_number and resolved_msg:
            sms_attempted = True
            sms_text = f"{resolved_msg}\n\n{_SMS_OPTOUT_SUFFIX}"
            sms_res = telnyx_sms.send_sms(to_number=to_number, from_number=from_number, text=sms_text)
            sms_api_accepted = bool(sms_res.get("success"))
            sms_telnyx_message_id = (sms_res.get("telnyx_message_id") or "").strip() or None
            logger.info(
                "[CAL_BOOK] sms_followup_sent to=%s from=%s success=%s telnyx_status=%s telnyx_msg_id=%s telnyx_error=%s",
                _mask_phone(to_number),
                _mask_phone(from_number),
                sms_res.get("success"),
                sms_res.get("status_code"),
                (sms_res.get("telnyx_message_id") or "")[:40],
                (sms_res.get("error") or "")[:100],
            )
            if sms_res.get("success") and appointment_id:
                now_iso = datetime.utcnow().isoformat() + "Z"
                updates = {"confirmation_message_sent_at": now_iso, "updated_at": now_iso}
                if followup.get("payment_link"):
                    updates["payment_link_sent_at"] = now_iso
                try:
                    supabase.table("appointments").update(updates).eq("id", appointment_id).execute()
                except Exception as up_ex:
                    logger.warning("[CAL_BOOK] failed to set confirmation_message_sent_at: %s", up_ex)
                telnyx_msg_id = sms_res.get("telnyx_message_id")
                if telnyx_msg_id:
                    try:
                        from telnyx.sms_webhook import store_sms_sent
                        store_sms_sent(
                            supabase=supabase,
                            telnyx_message_id=telnyx_msg_id,
                            appointment_id=appointment_id,
                            to_number=to_number,
                        )
                    except Exception as store_ex:
                        logger.warning("[CAL_BOOK] store_sms_sent failed: %s", store_ex)
        else:
            logger.info(
                "[CAL_BOOK] booking_created_no_followup_channel reason=no_to_number caller_phone_present=%s",
                bool(to_number_raw),
            )
    except Exception as ex:
        logger.warning("[CAL_BOOK] sms_followup_failed (booking kept): %s", ex)

    sms_followup = {
        "attempted": sms_attempted,
        "api_accepted": sms_api_accepted,
        "telnyx_message_id": sms_telnyx_message_id,
        "from_number_is_toll_free": bool(sms_from_for_telemetry and is_us_toll_free_e164(sms_from_for_telemetry)),
        "delivery": "unknown",
    }
    if sms_attempted and sms_api_accepted:
        logger.info(
            "[CAL_BOOK] sms_api_accepted_downstream_unknown msg_id=%s toll_free_sender=%s",
            (sms_telnyx_message_id or "")[:36],
            sms_followup["from_number_is_toll_free"],
        )

    return {
        "success": True,
        "event_id": event.get("id"),
        "html_link": event.get("htmlLink"),
        "start": event.get("start", {}).get("dateTime") or event.get("start", {}).get("date"),
        "end": event.get("end", {}).get("dateTime") or event.get("end", {}).get("date"),
        "summary": event.get("summary"),
        "followup_mode": followup.get("followup_mode"),
        "followup_message_resolved": followup.get("followup_message_resolved"),
        "payment_link": followup.get("payment_link"),
        "meeting_instructions": followup.get("meeting_instructions"),
        "owner_selected_platform": followup.get("owner_selected_platform"),
        "sms_followup": sms_followup,
    }


def handle_reschedule(
    service,
    calendar_id: str,
    params: dict,
    *,
    default_timezone: str,
    default_slot_minutes: int,
    parse_datetime_range_fn,
    receptionist_id: str | None = None,
    supabase=None,
) -> dict:
    event_id = params.get("event_id")
    timezone = (params.get("timezone") or default_timezone).strip() or default_timezone
    new_start = params.get("new_start") or params.get("date_text")
    duration_minutes = params.get("duration_minutes") or default_slot_minutes
    if isinstance(duration_minutes, str):
        try:
            duration_minutes = int(duration_minutes) or default_slot_minutes
        except (ValueError, TypeError):
            duration_minutes = default_slot_minutes

    if not event_id:
        return {"success": False, "error": "event_id_missing", "message": "Which appointment should I reschedule?"}
    if not new_start:
        return {"success": False, "error": "date_missing", "message": "What new day and time would you like?"}

    try:
        logger.info("[CAL_DATE] reschedule input=%r timezone=%s", new_start, timezone)
        start_d = parse_iso_datetime_or_natural(new_start, timezone=timezone)
        if not start_d:
            return {"success": False, "error": "date_parse_failed", "message": "I couldn't understand the new date/time. What day and time should I move it to?"}
        try:
            start_d = _ensure_aware_wall_time(start_d, timezone)
        except Exception:
            return {"success": False, "error": "date_parse_failed", "message": "I couldn't understand the new date/time. What day and time should I move it to?"}
        end_d = start_d + timedelta(minutes=duration_minutes)
    except (ValueError, TypeError):
        return {"success": False, "error": "date_parse_failed", "message": "I couldn't understand the new date/time. What day and time should I move it to?"}

    try:
        event = service.events().patch(
            calendarId=calendar_id,
            eventId=event_id,
            body={
                "start": {"dateTime": start_d.isoformat(), "timeZone": timezone},
                "end": {"dateTime": end_d.isoformat(), "timeZone": timezone},
            },
            sendUpdates="none",
        ).execute()

        if supabase and receptionist_id:
            start_iso = start_d.isoformat()
            end_iso = end_d.isoformat()
            now_iso = datetime.utcnow().isoformat() + "Z"
            try:
                up_res = (
                    supabase.table("appointments")
                    .update(
                        {
                            "start_time": start_iso,
                            "end_time": end_iso,
                            "duration_minutes": duration_minutes,
                            "updated_at": now_iso,
                        }
                    )
                    .eq("receptionist_id", receptionist_id)
                    .eq("event_id", event_id)
                    .execute()
                )
                rows = getattr(up_res, "data", None) or []
                if not rows:
                    logger.warning(
                        "[CAL_BOOK] reschedule_no_appointment_row receptionist_id=%s event_id=%s",
                        receptionist_id,
                        event_id,
                    )
            except Exception as ex:
                logger.warning(
                    "[CAL_BOOK] reschedule_appointments_update_failed receptionist_id=%s event_id=%s error=%s",
                    receptionist_id,
                    event_id,
                    ex,
                )

        return {
            "success": True,
            "event_id": event.get("id"),
            "start": event.get("start", {}).get("dateTime") or event.get("start", {}).get("date"),
            "end": event.get("end", {}).get("dateTime") or event.get("end", {}).get("date"),
            "summary": event.get("summary"),
        }
    except Exception as e:
        msg = str(e)
        if "Conflict" in msg or "409" in msg or "not found" in msg.lower():
            range_data, _parse_mode = parse_datetime_range_fn(new_start, timezone=timezone)
            if range_data:
                freebusy_res = service.freebusy().query(
                    body={
                        "timeMin": range_data["timeMin"],
                        "timeMax": range_data["timeMax"],
                        "items": [{"id": calendar_id}],
                    }
                ).execute()
                busy = freebusy_res.get("calendars", {}).get(calendar_id, {}).get("busy") or []
                suggested = get_free_slots(
                    busy=busy,
                    time_min=range_data["timeMin"],
                    time_max=range_data["timeMax"],
                    slot_minutes=duration_minutes,
                )[:5]
                return {
                    "success": False,
                    "error": "slot_unavailable",
                    "message": "That time slot is not available.",
                    "suggested_slots": suggested,
                }
            return {
                "success": False,
                "error": "slot_unavailable",
                "message": "That time slot is not available.",
                "suggested_slots": [],
            }
        raise

