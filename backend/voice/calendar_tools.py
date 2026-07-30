"""Calendar tool definitions for Grok function calling."""

import httpx

CALENDAR_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "check_availability",
            "description": "Check available time slots in the calendar for a given date. Returns exact_slots (ISO times you may offer), summary_periods (morning/afternoon/evening with availability), and suggested_slots (capped at 3). When services are configured: (a) if the caller names a service, pass service_name; (b) if they want a general appointment, pass generic_appointment_requested=true. CRITICAL: Only speak slots that appear in the tool result. If suggested_slots or exact_slots contain specific times, speak ONLY those exact times—never infer or add times like '2 PM is available too' unless the tool returned that slot. If only summary_periods are returned (e.g. morning, afternoon), speak only those periods. Do not mention timezone unless the caller asks or ambiguity blocks booking.",
            "parameters": {
                "type": "object",
                "properties": {
                    "date_text": {
                        "type": "string",
                        "description": "Natural language date/time like 'tomorrow at 4', 'March 17th at 7pm', 'next Friday morning'. Preferred when caller speaks naturally.",
                    },
                    "start_date": {
                        "type": "string",
                        "description": "ISO date (YYYY-MM-DD) or ISO datetime. Use if already normalized; otherwise pass date_text.",
                    },
                    "end_date": {"type": "string", "description": "Optional end date if checking a date range"},
                    "duration_minutes": {"type": "string", "description": "Appointment duration in minutes (default 30)"},
                    "timezone": {"type": "string", "description": "Only pass if caller's location suggests a different timezone; omit to use business default. Do not mention timezone to caller unless they ask or it blocks booking."},
                    "service_name": {
                        "type": "string",
                        "description": "Name of the service the caller selected (e.g. Business consulting). If the caller names a configured service, pass it exactly so the backend can proceed. Do not ask for extra specificity if they already named one.",
                    },
                    "service_id": {
                        "type": "string",
                        "description": "UUID of the service if known. Prefer service_name when the caller spoke the service name.",
                    },
                    "generic_appointment_requested": {
                        "type": "boolean",
                        "description": "Set to true when the caller explicitly wants a general appointment with no specific service.",
                    },
                    "store_name": {
                        "type": "string",
                        "description": "Store/branch name when the business has multiple locations. Pass the caller's chosen location so availability uses that store's calendar.",
                    },
                    "location_id": {
                        "type": "string",
                        "description": "UUID of the store/location if known. Prefer store_name when the caller spoke the location name.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_appointment",
            "description": "Create a new appointment/booking in the calendar. Use after the caller has chosen a time slot. If the service requires a location, you must collect and pass location_type and location_text or customer_address before calling. After success: give ONE concise spoken confirmation, e.g. \"Done — you're booked for tomorrow at 2 PM.\" Do not repeat extra metadata (event ID, link, etc). Do not read follow-up message content aloud—that is sent via SMS.",
            "parameters": {
                "type": "object",
                "properties": {
                    "date_text": {"type": "string", "description": "Natural language date/time for the appointment start (e.g. 'tomorrow at 4')."},
                    "start_time": {"type": "string", "description": "ISO datetime for appointment start"},
                    "duration_minutes": {"type": "string", "description": "Duration in minutes (default 30)"},
                    "summary": {"type": "string", "description": "Appointment title/summary (e.g. client name and service)"},
                    "description": {"type": "string", "description": "Optional additional details"},
                    "attendees": {"type": "array", "description": "Optional array of attendee email addresses", "items": {"type": "string"}},
                    "service_id": {"type": "string", "description": "UUID of the service if booking a configured service."},
                    "service_name": {"type": "string", "description": "Name of the service (e.g. House Cleaning) for the appointment."},
                    "location_type": {"type": "string", "description": "One of: no_location, customer_address, phone_call, video_meeting, custom. For configured services, follow the owner's configured default_location_type; do NOT ask the caller to choose Zoom/Meet/FaceTime/etc."},
                    "location_text": {"type": "string", "description": "Free-form location/instructions. For customer_address, use customer_address instead. For custom, include the custom instructions. Do NOT ask callers to pick a video platform."},
                    "customer_address": {"type": "string", "description": "Street address when location_type is customer_address (e.g. 123 Main St, Apt 4B)."},
                    "notes": {"type": "string", "description": "Optional notes (e.g. buzz code, gate instructions)."},
                    "price_cents": {"type": "integer", "description": "Optional price in cents for the appointment. For configured services, the backend prefers the stored service price when set."},
                    "caller_phone": {"type": "string", "description": "Caller phone number (E.164) for immediate post-booking SMS follow-up."},
                    "store_name": {
                        "type": "string",
                        "description": "Store/branch name when the business has multiple locations. Pass so the booking lands on that store's calendar.",
                    },
                    "location_id": {
                        "type": "string",
                        "description": "UUID of the store/location if known. Prefer store_name when the caller spoke the location name.",
                    },
                },
                "required": ["summary"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "reschedule_appointment",
            "description": "Reschedule an existing appointment to a new time. Use when the caller wants to change an existing booking.",
            "parameters": {
                "type": "object",
                "properties": {
                    "event_id": {"type": "string", "description": "The calendar event ID to reschedule"},
                    "date_text": {"type": "string", "description": "Natural language new date/time (e.g. 'next Tuesday at 11')."},
                    "new_start": {"type": "string", "description": "New ISO datetime for the appointment"},
                    "duration_minutes": {"type": "string", "description": "Duration in minutes (default 30)"},
                },
                "required": ["event_id"],
            },
        },
    },
]


async def call_calendar_tool(
    base_url: str,
    api_key: str,
    receptionist_id: str,
    action: str,
    args: dict,
    *,
    call_control_id: str | None = None,
) -> str:
    """Execute calendar tool via voice calendar API."""
    url = f"{base_url.rstrip('/')}/api/voice/calendar"
    normalized: dict = {}
    for k, v in args.items():
        if v is None:
            continue
        if k == "duration_minutes" and isinstance(v, str):
            try:
                normalized[k] = int(v) or 30
            except (ValueError, TypeError):
                normalized[k] = 30
        elif k == "price_cents" and v is not None:
            try:
                normalized[k] = int(v)
            except (TypeError, ValueError):
                pass
        elif k == "attendees" and isinstance(v, list):
            normalized[k] = [x for x in v if isinstance(x, str)]
        else:
            normalized[k] = v

    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(
                url,
                headers={
                    "Content-Type": "application/json",
                    "x-voice-server-key": api_key,
                    "x-voice-api-key": api_key,
                },
                json={
                    "receptionist_id": receptionist_id,
                    "action": action,
                    "params": normalized,
                    "call_control_id": call_control_id,
                },
            )
            return resp.text
    except Exception as e:
        import json
        return json.dumps({"success": False, "error": str(e)})
