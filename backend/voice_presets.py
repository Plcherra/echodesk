"""Curated voice presets for receptionist creation and settings.
   Mobile uses preset keys only; voice_id (google_voice_name) is resolved server-side.
   Google Cloud TTS only; preset -> google_voice_name mapping.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from config import settings

# NOTE: Preset keys are stable identifiers (API + DB). Labels/descriptions may evolve over time.
DEFAULT_PRESET_KEY = "professional_calm"  # Resolves to en-US-Neural2-C (direct, fast default)

# Single shared neutral preview sentence. Voice presets must affect audio only, not content.
PREVIEW_SAMPLE_TEXT = "Hello, thanks for calling. How can I help you today?"

# Curated presets for AI receptionist use. Google Cloud TTS voice mappings only.
VOICE_PRESETS: list[dict[str, Any]] = [
    {
        "key": "friendly_warm",
        "label": "Friendly & Warm",
        "description": "Warm and approachable — great for salons, wellness, and small businesses.",
        "gender_or_style_label": "Warm, approachable",
        "google_voice_name": "en-US-Neural2-F",
        "google_language_code": "en-US",
        "pocket_voice": None,  # unused until Phase 6 full cutover
        "sample_text": PREVIEW_SAMPLE_TEXT,
    },
    {
        "key": "professional_calm",
        "label": "Professional & Calm",
        "description": "Clear and composed — ideal for offices, consulting, and professional services.",
        "gender_or_style_label": "Professional, calm",
        "google_voice_name": "en-US-Neural2-C",
        "google_language_code": "en-US",
        "pocket_voice": None,  # unused until Phase 6 full cutover
        "sample_text": PREVIEW_SAMPLE_TEXT,
    },
    {
        "key": "premium_concierge",
        "label": "Premium Concierge",
        "description": "Polished and attentive — suits hospitality, high-end services, and concierge.",
        "gender_or_style_label": "Polished, attentive",
        "google_voice_name": "en-US-Neural2-J",
        "google_language_code": "en-US",
        "pocket_voice": None,  # unused until Phase 6 full cutover
        "sample_text": PREVIEW_SAMPLE_TEXT,
    },
    {
        "key": "energetic_upbeat",
        "label": "Energetic & Upbeat",
        "description": "Lively and positive — good for fitness, events, and youth-oriented brands.",
        "gender_or_style_label": "Energetic, upbeat",
        "google_voice_name": "en-US-Neural2-D",
        "google_language_code": "en-US",
        "pocket_voice": None,  # unused until Phase 6 full cutover
        "sample_text": PREVIEW_SAMPLE_TEXT,
    },
    {
        "key": "confident_clear",
        "label": "Confident & Clear",
        "description": "Assured and easy to understand — works for legal, medical, or any clarity-focused use.",
        "gender_or_style_label": "Confident, clear",
        "google_voice_name": "en-US-Neural2-A",
        "google_language_code": "en-US",
        "pocket_voice": None,  # unused until Phase 6 full cutover
        "sample_text": PREVIEW_SAMPLE_TEXT,
    },
]

PRESET_KEYS = {p["key"] for p in VOICE_PRESETS}


def infer_preset_key_from_voice_id(voice_id: str | None) -> str | None:
    """Best-effort inference for legacy records: map stored voice_id (google_voice_name) back to preset key."""
    vid = (voice_id or "").strip()
    if not vid:
        return None
    for p in VOICE_PRESETS:
        if (p.get("google_voice_name") or "").strip() == vid:
            return p["key"]
    return None


def get_preset(key: str) -> dict[str, Any] | None:
    """Return preset by key, or None."""
    for p in VOICE_PRESETS:
        if p["key"] == key:
            return p
    return None


# Fallback voice id (google_voice_name from default preset) when no preset key + no stored voice_id exists.
_dp = get_preset(DEFAULT_PRESET_KEY)
ENV_DEFAULT_VOICE_ID: str | None = (_dp.get("google_voice_name") if _dp else None) or None


@dataclass(frozen=True)
class ResolvedTtsVoice:
    """Resolved TTS voice from preset + optional Pocket clone.

    Clone wins when voice_clone_id + pocket_voice_path are set.
    Google fields always stay populated so clone failures can fall back.
    """

    google_language_code: str
    google_voice_name: str
    model_id: str | None
    provider: str = "google"  # google | pocket
    voice_clone_id: str | None = None
    pocket_voice_path: str | None = None
    pocket_voice: str | None = None  # unused until Phase 6 preset cutover


def resolve_voice_id(voice_preset_key: str | None, fallback_voice_id: str | None) -> str | None:
    """Resolve preset key to voice_id (google_voice_name) for DB storage.

    Rules:
    - valid preset key -> preset google_voice_name
    - missing preset key + existing voice_id -> keep existing voice_id (backward compatibility)
    - invalid preset key -> default preset google_voice_name
    """
    key = (voice_preset_key or "").strip() or None
    fb = (fallback_voice_id or "").strip() or None

    if key:
        preset = get_preset(key)
        if preset:
            return (preset.get("google_voice_name") or "").strip() or None
        default_preset = get_preset(DEFAULT_PRESET_KEY)
        return (default_preset.get("google_voice_name") if default_preset else None) or ENV_DEFAULT_VOICE_ID

    # No preset key supplied: keep stored voice_id if present
    return fb or ENV_DEFAULT_VOICE_ID


def resolve_tts_voice(
    voice_preset_key: str | None,
    fallback_voice_id: str | None,
    *,
    voice_clone_id: str | None = None,
    pocket_voice_path: str | None = None,
) -> ResolvedTtsVoice:
    """Resolve Google voice (and optional Pocket clone) from preset + storage.

    Rule: clone wins when voice_clone_id is set and an embedding path exists.
    """
    key = (voice_preset_key or "").strip() or None
    fb = (fallback_voice_id or "").strip() or None

    preset: dict[str, Any] | None = None
    if key:
        preset = get_preset(key) or get_preset(DEFAULT_PRESET_KEY)
    elif fb:
        inferred = infer_preset_key_from_voice_id(fb)
        if inferred:
            preset = get_preset(inferred)

    if preset:
        gname = (preset.get("google_voice_name") or "").strip() or (settings.google_tts_default_voice_name or "").strip()
        glang = (preset.get("google_language_code") or "").strip() or (settings.google_tts_default_language_code or "en-US").strip()
        pocket_voice = (preset.get("pocket_voice") or "").strip() or None
    else:
        gname = (settings.google_tts_default_voice_name or "en-US-Neural2-C").strip()
        glang = (settings.google_tts_default_language_code or "en-US").strip()
        pocket_voice = None

    clone_id = (voice_clone_id or "").strip() or None
    clone_path = (pocket_voice_path or "").strip() or None
    use_pocket = bool(clone_id and clone_path and settings.voice_clone_enabled)
    return ResolvedTtsVoice(
        google_language_code=glang,
        google_voice_name=gname,
        model_id=None,
        provider="pocket" if use_pocket else "google",
        voice_clone_id=clone_id if use_pocket else None,
        pocket_voice_path=clone_path if use_pocket else None,
        pocket_voice=pocket_voice,
    )


def google_voice_allowlist() -> frozenset[str]:
    """Allowed Google voice names: env list, or all preset + default + backup voices."""
    raw = (settings.google_tts_voice_allowlist or "").strip()
    if raw:
        return frozenset(x.strip() for x in raw.split(",") if x.strip())
    names: set[str] = set()
    for p in VOICE_PRESETS:
        gn = (p.get("google_voice_name") or "").strip()
        if gn:
            names.add(gn)
    names.add((settings.google_tts_default_voice_name or "").strip())
    names.add((settings.google_tts_backup_voice_name or "").strip())
    return frozenset(n for n in names if n)


def list_presets_for_api() -> list[dict[str, Any]]:
    """Return presets for mobile API: no voice_id (internal only). Include preview_path for playback."""
    out = []
    for p in VOICE_PRESETS:
        out.append({
            "key": p["key"],
            "label": p["label"],
            "description": p["description"],
            "gender_or_style_label": p.get("gender_or_style_label"),
            "sample_text": p.get("sample_text"),
            "preview_path": f"/api/mobile/voice-presets/{p['key']}/preview",
        })
    return out
