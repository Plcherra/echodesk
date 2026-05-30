"""Shared constants for the voice pipeline (debounce, history, spoken prompts)."""

from config import settings

MAX_HISTORY = 20
DEBOUNCE_MS = 1200
DEBOUNCE_MS_FALLBACK = 800
SHORT_PAUSE_MAX_WORDS = 4
MIN_CONFIDENCE = 0.35

FAST_ACK_AVAILABILITY = "Checking now."
FAST_ACK_BOOKING = "Got it. Booking now."

# Voice output: assistant must output only literal spoken words (no narration/actions)
VOICE_OUTPUT_INSTRUCTIONS = (
    "\n\nVoice output rules: Your replies are spoken aloud. Output ONLY the literal words to be spoken. "
    "Never include emojis, emoticons (e.g. :)), stage directions, or action narration such as (smiles), [laughs], *pause*, or standalone words like 'Smile' or 'Smiles' used as action text. "
    "Keep content suitable for text-to-speech: no markup, no parenthetical asides that are not meant to be spoken."
)


def _clamp_int(value: object, *, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = default
    return max(minimum, min(maximum, parsed))


def voice_debounce_ms() -> int:
    """Default post-final debounce, capped so env tuning cannot create huge dead air."""
    return _clamp_int(settings.voice_debounce_ms, default=DEBOUNCE_MS, minimum=300, maximum=2000)


def voice_debounce_fallback_ms() -> int:
    """Short-utterance debounce, capped to keep slot selections feeling quick."""
    return _clamp_int(
        settings.voice_debounce_fallback_ms,
        default=DEBOUNCE_MS_FALLBACK,
        minimum=150,
        maximum=1200,
    )
