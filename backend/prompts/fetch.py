"""Fetch receptionist prompt from cache or Supabase."""

from __future__ import annotations

import asyncio
import logging
from typing import Optional

from prompts.builder import build_receptionist_prompt
from voice.constants import DEFAULT_GREETING

logger = logging.getLogger(__name__)

# In-memory prompt cache:
# call_control_id -> (prompt, greeting, voice_id | None, voice_preset_key | None, greeting_source, assistant_identity)
_prompt_cache: dict[str, tuple[str, str, Optional[str], Optional[str], str, str]] = {}
_MAX_PROMPT_CACHE = 1000

DEFAULT = (
    "You are an AI receptionist. Be helpful and concise.",
    DEFAULT_GREETING,
    None,
    None,
    "fallback",
    "Receptionist",
)


def set_prompt(
    call_control_id: str,
    prompt: str,
    greeting: str,
    voice_id: Optional[str] = None,
    voice_preset_key: Optional[str] = None,
    greeting_source: str = "custom",
    assistant_identity: str = "Receptionist",
) -> None:
    if call_control_id and len(_prompt_cache) >= _MAX_PROMPT_CACHE:
        try:
            oldest_key = next(iter(_prompt_cache.keys()))
            _prompt_cache.pop(oldest_key, None)
            logger.warning(
                "[CALL_DIAG] prompt_cache_evicted oldest_call_control_id=%s size=%s",
                oldest_key,
                len(_prompt_cache),
            )
        except Exception:
            _prompt_cache.clear()
            logger.warning("[CALL_DIAG] prompt_cache_cleared size_limit=%s", _MAX_PROMPT_CACHE)
    _prompt_cache[call_control_id] = (
        prompt,
        greeting,
        voice_id,
        voice_preset_key,
        greeting_source,
        assistant_identity or "Receptionist",
    )


def get_cached_prompt(call_control_id: str) -> tuple[str, str, Optional[str], Optional[str], str, str] | None:
    return _prompt_cache.get(call_control_id)


def clear_cached_prompt(call_control_id: str) -> None:
    """Best-effort cleanup hook (call lifetime)."""
    if not call_control_id:
        return
    _prompt_cache.pop(call_control_id, None)


async def fetch_prompt(receptionist_id: str, supabase) -> tuple[str, str, Optional[str], Optional[str], str, str]:
    """Fetch prompt for receptionist from Supabase. Returns (prompt, greeting, voice_id, voice_preset_key, greeting_source)."""
    if not receptionist_id or not receptionist_id.strip():
        return DEFAULT
    return await asyncio.to_thread(_build_from_supabase_sync, receptionist_id, supabase)


def _build_from_supabase_sync(receptionist_id: str, supabase) -> tuple[str, str, Optional[str], Optional[str], str, str]:
    default = DEFAULT
    if not receptionist_id or not receptionist_id.strip():
        return default

    rec_res = supabase.table("receptionists").select(
        "id, name, user_id, phone_number, calendar_id, payment_settings, website_content, "
        "extra_instructions, system_prompt, greeting, voice_id, voice_preset_key, assistant_identity"
    ).eq("id", receptionist_id).execute()

    if not rec_res.data or len(rec_res.data) == 0:
        return default

    rec = rec_res.data[0]
    name = rec.get("name", "Receptionist")
    identity = (rec.get("assistant_identity") or "").strip() or name

    # Precedence: system_prompt if set, else generated
    custom_prompt = (rec.get("system_prompt") or "").strip()
    if custom_prompt:
        prompt = custom_prompt
        if (rec.get("extra_instructions") or "").strip():
            prompt += f"\n\nAdditional instructions from the business:\n{rec['extra_instructions'].strip()}"
    else:
        staff_res = supabase.table("staff").select("name, role, specialties").eq("receptionist_id", receptionist_id).order("name").execute()
        services_res = supabase.table("services").select("name, description, price_cents, duration_minutes, category, requires_location, default_location_type").eq("receptionist_id", receptionist_id).execute()
        locations_res = supabase.table("locations").select("name, address, notes").eq("receptionist_id", receptionist_id).execute()
        promos_res = supabase.table("promos").select("description, code, discount_type, discount_value").eq("receptionist_id", receptionist_id).execute()
        rules_res = supabase.table("reminder_rules").select("type, content").eq("receptionist_id", receptionist_id).execute()

        staff = staff_res.data or []
        services = services_res.data or []
        locations = locations_res.data or []
        promos = promos_res.data or []
        reminder_rules = rules_res.data or []

        prompt = build_receptionist_prompt(
            name=identity,
            phone_number=rec.get("phone_number", ""),
            calendar_id=rec.get("calendar_id", "primary") or "primary",
            staff=staff,
            services=services,
            locations=locations,
            promos=promos,
            reminder_rules=reminder_rules,
            payment_settings=rec.get("payment_settings"),
            website_content=rec.get("website_content"),
            extra_instructions=rec.get("extra_instructions"),
            compact=True,
        )

    # Precedence: greeting if set, else default with identity
    custom_greeting = (rec.get("greeting") or "").strip()
    if custom_greeting:
        greeting = custom_greeting
        greeting_source = "custom"
    else:
        greeting = DEFAULT_GREETING
        greeting_source = "fallback"

    # Precedence: voice_id if set, else None (caller uses env default)
    voice_id = (rec.get("voice_id") or "").strip() or None
    voice_preset_key = (rec.get("voice_preset_key") or "").strip() or None

    logger.info(
        "[receptionist config] receptionist_id=%s prompt_source=%s greeting_source=%s voice_id=%s",
        receptionist_id,
        "custom" if custom_prompt else "generated",
        greeting_source,
        "custom" if voice_id else "env_default",
    )
    return prompt, greeting, voice_id, voice_preset_key, greeting_source, identity
