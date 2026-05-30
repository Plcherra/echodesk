"""Build system prompt for receptionist from DB data."""

from typing import Any, Optional

from prompts.personas import get_persona

MAX_PROMPT_CHARS = 28000
COMPACT_SERVICES_LIMIT = 10
COMPACT_STAFF_LIMIT = 15

TONE_GUIDANCE = {
    "professional": "Use a professional, polished tone. Be courteous and efficient. Avoid slang.",
    "warm": "Be warm, friendly, and personable. Use a welcoming tone while staying concise.",
    "casual": "Keep it conversational and relaxed. You can use a slightly informal tone when appropriate.",
    "formal": "Use formal language and titles. Be highly polite and structured.",
}

CUSTOM_PROMPT_GUARDRAILS = (
    "Non-negotiable voice safety rules: Keep replies to 1-2 short spoken sentences unless the caller asks for details. "
    "Never invent availability, times, prices, services, policies, or booking details. "
    "Use calendar tools for availability, booking, and rescheduling. "
    "Speak only returned exact_slots, suggested_slots, or summary_periods. "
    "Never expose raw JSON, event IDs, tool metadata, payment links, or technical errors to the caller."
)


def build_receptionist_prompt(
    name: str,
    phone_number: str,
    calendar_id: str,
    staff: list[dict[str, Any]],
    services: list[dict[str, Any]],
    locations: list[dict[str, Any]],
    promos: list[dict[str, Any]],
    reminder_rules: list[dict[str, Any]],
    payment_settings: Optional[dict[str, Any]] = None,
    website_content: Optional[str] = None,
    extra_instructions: Optional[str] = None,
    tone: Optional[str] = None,
    persona_key: Optional[str] = None,
    business_type: Optional[str] = None,
    compact: bool = False,
) -> str:
    sections = []
    persona = get_persona(persona_key)
    effective_tone = (tone or persona.tone or "warm").lower()

    # 1. Invariant identity and safety rules
    recording = "This call may be recorded for quality and training purposes. By continuing, the caller consents to recording. "
    sections.append(
        f"{recording}You are an AI receptionist named {name}. You represent this business on the phone. The business phone number is {phone_number}. "
        "Never invent availability, prices, policies, services, or booking details. Never expose raw JSON, event IDs, tool metadata, payment links, or technical errors to the caller."
    )

    # 1b. Conversation memory
    sections.append(
        "Conversation memory: Use this call's history. Remember the caller's name, requested service, date/time discussed, and details already shared. If they revise something, update the previous request instead of starting over. Never ask again for information they already gave."
    )

    # 2. Tone and style
    tone_text = TONE_GUIDANCE.get(effective_tone, TONE_GUIDANCE["warm"])
    business_ctx = f" This is a {business_type.strip()} business." if business_type and business_type.strip() else ""
    sections.append(
        f"Persona: {persona.label}. {persona.style_rule} {tone_text}{business_ctx} Keep responses to 1-2 short spoken sentences unless the caller asks for details. {persona.recovery_style}"
    )

    # 3. Tool usage (calendar)
    sections.append(
        f"Calendar tools: The calendar ID is {calendar_id}. Use tools for availability, booking, and rescheduling. Accept natural dates like 'tomorrow at 4' or 'next Friday morning'. Ask a follow-up only when date/time/service is missing or genuinely ambiguous. Speak only returned exact_slots, suggested_slots, or summary_periods. If slot_unavailable returns suggestions, offer only those suggestions."
    )

    # 4. Business knowledge
    if website_content and website_content.strip():
        sections.append(f"About the business (from website):\n{website_content.strip()}")

    if staff:
        staff_list = staff[:COMPACT_STAFF_LIMIT] if compact else staff
        parts = []
        for s in staff_list:
            spec = ""
            if s.get("specialties"):
                sp = s["specialties"]
                spec = ", ".join(sp) if isinstance(sp, list) else str(sp)
            role = s.get("role") or "staff"
            if spec:
                parts.append(f"{s.get('name', '')} ({role}): {spec}")
            else:
                parts.append(f"{s.get('name', '')}{f', {role}' if role else ''}")
        sections.append(f"Staff: {' '.join(parts)}. When relevant, suggest booking with a specific staff member or \"anyone available.\"")

    if services:
        svc_list = services[:COMPACT_SERVICES_LIMIT] if compact else services
        parts = []
        for s in svc_list:
            price = f"${(s.get('price_cents') or 0) / 100:.2f}"
            dur = f", {s.get('duration_minutes', 0)} min" if s.get("duration_minutes") else ""
            desc = f" ({s.get('description')})" if s.get('description') and not compact else ""
            loc_req = " [requires location]" if s.get("requires_location") else ""
            loc_type = (s.get("default_location_type") or "").strip()
            loc_cfg = f" [location_type={loc_type}]" if loc_type else ""
            parts.append(f"{s.get('name', '')}: {price}{dur}{desc}{loc_req}{loc_cfg}")
        sections.append(f"Services and pricing: {'; '.join(parts)}. Quote prices and duration when asked.")
        any_requires_location = any(s.get("requires_location") for s in svc_list)
        if any_requires_location:
            sections.append(
                "Location: Follow each service's configured location_type. Do not ask the caller to choose Zoom, Meet, FaceTime, WhatsApp, or another platform. Only collect the missing required detail: address for customer_address, or exact instructions for custom. For phone_call or video_meeting, do not ask for a platform."
            )

    if locations:
        parts = []
        for l in locations:
            if l.get("address"):
                note = f" ({l.get('notes')})" if l.get("notes") else ""
                parts.append(f"{l.get('name', '')} at {l['address']}{note}")
            else:
                parts.append(l.get("name", ""))
        sections.append(f"Locations: {'. '.join(parts)}.")

    if payment_settings:
        ps = payment_settings
        ps_parts = []
        if ps.get("payment_methods"):
            ps_parts.append(f"Accepted: {', '.join(ps['payment_methods'])}.")
        if ps.get("accept_deposit") and ps.get("deposit_amount_cents"):
            ps_parts.append(f"Deposit to secure booking: ${ps['deposit_amount_cents'] / 100:.2f}.")
        ps_parts.append("Tell callers you'll send a secure payment link via text after you confirm their booking.")
        if ps.get("refund_policy"):
            ps_parts.append(f"Refund policy: {ps['refund_policy']}")
        sections.append(f"Payment: {' '.join(ps_parts)}")

    if reminder_rules:
        rules = " ".join(r.get("content", "") for r in reminder_rules)
        sections.append(f"Policies and rules: {rules}")

    if promos:
        parts = []
        for p in promos:
            desc = p.get("description", "")
            val = p.get("discount_value")
            typ = p.get("discount_type")
            suffix = f" ({val}{'%' if typ == 'percent' else ''} off)" if val is not None else ""
            parts.append(f"{p.get('code', '')}: {desc}{suffix}")
        sections.append(f"Current promos: {'; '.join(parts)}.")

    # 5. Clarification and error recovery
    sections.append(
        "Recovery: Ask for one missing piece at a time. If you did not hear clearly, say: \"I'm sorry, I didn't catch that. Could you repeat that?\" If a tool or calendar fails, say: \"I'm having trouble with the calendar right now. Could you try again in a moment?\" Do not mention internal systems or technical errors."
    )

    # 6. Service-before-availability (when services exist)
    if services:
        sections.append(
            "Service-first: If the caller names a configured service, use it immediately and pass service_name to tools. Do not ask for more specificity when the service matches. If they only say they want to book, ask what they want to book or whether it is a general appointment."
        )

    # 7. Booking flow
    sections.append(
        f"Booking flow: Collect service or generic appointment type, date/time or availability window, required location details, caller name, and optional phone. Before creating or changing an appointment, briefly summarize the essential details and ask if that is right. After success, {persona.confirmation_style} Do not mention timezone unless the caller asks or ambiguity blocks booking."
    )

    # 8. Post-booking (short confirmation only; no SMS content on call)
    sections.append(
        "After booking: Give one concise spoken confirmation, such as \"You're all set for tomorrow at 2 PM.\" Do not speak follow-up message content, payment links, meeting instructions, event IDs, or review text."
    )

    # 9. When no services are configured: generic appointment + optional location
    if not services:
        sections.append(
            "No services are configured (generic booking): Follow this exact order and be deterministic. "
            "(1) Collect the date. (2) Collect the exact start time. (3) Collect the duration in minutes. "
            "(4) Collect the caller's name. Once you have all 4, call create_appointment exactly once. "
            "Set summary to include their name, e.g. \"Appointment — {caller_name}\". "
            "Do NOT re-run check_availability repeatedly if the caller has not changed the requested date/time. "
            "If you already offered valid times and the caller picked one, proceed to booking; only re-check availability if the calendar tool returns slot_unavailable or if the caller changes the date/time. "
            "After the booking attempt: if success=true, confirm with one short sentence. If success=false, explain the failure; if suggested_slots are provided, offer only those alternatives. Never invent times. "
            "For location: only ask if they say they need a location. If they do, ask whether it's a customer address, phone call, video meeting, or custom; then collect the address/details and pass location_type plus customer_address or location_text."
        )

    if extra_instructions and extra_instructions.strip():
        sections.append(f"Additional instructions from the business:\n{extra_instructions.strip()}")

    full = "\n\n".join(sections)
    if len(full) > MAX_PROMPT_CHARS:
        full = full[:MAX_PROMPT_CHARS] + "\n\n[Prompt truncated for length. Consider using compact mode or fewer items.]"
    return full
