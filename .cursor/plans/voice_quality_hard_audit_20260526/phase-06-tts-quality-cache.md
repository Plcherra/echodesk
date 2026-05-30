# Phase 06 - TTS Voice Quality, Caching, and Pronunciation

## Goal

Make the assistant sound polished, warm, and consistent over telephone audio.

## Why This Matters

Good speech text can still sound bad if the voice, speaking rate, pitch, chunking, or pronunciation is off. Telephony audio is only 8 kHz, so each phrase must be designed for that channel.

## Current Evidence

- Google Neural2 presets exist in `backend/voice_presets.py`.
- Global speaking rate is `1.22` and pitch is `0.0` in `backend/config.py`.
- TTS cache infrastructure exists, and the default backend is `filesystem`.
- TTS sanitizer exists, but there is no broader pronunciation dictionary or SSML layer.
- Phase 06 slice 1 adds plain-text pronunciation normalization before Google TTS and cache key generation.
- Phase 06 slice 1 adds best-effort common phrase cache warming after startup audio.

## Implementation Plan

1. Run a voice preset listening matrix:
   - Friendly & Warm
   - Professional & Calm
   - Premium Concierge
   - Energetic & Upbeat
   - Confident & Clear
2. Test rate/pitch combinations:
   - rate 1.00, 1.08, 1.15, 1.22
   - pitch -1.0, 0.0, +1.0
3. Enable cache for production:
   - memory for single-process
   - filesystem or Redis/GCS for persistent multi-process
   - Status: filesystem cache remains the default, with common phrase warmup enabled by `TTS_WARM_COMMON_PHRASES`.
4. Add phrase-level cache warming for:
   - startup greeting
   - consent
   - pre-ack phrases
   - common recovery phrases
   - Status: slice 1 warms high-frequency pre-ack and recovery phrases in the background after startup audio.
5. Add pronunciation normalization:
   - phone numbers
   - times
   - business names
   - acronyms
   - prices
   - Status: slice 1 covers US phone numbers, compact times, prices, and common acronyms.
6. Consider optional SSML for pauses and pronunciation if Google voice supports the needed behavior.

## Acceptance Criteria

- Chosen default voice/rate/pitch passes listening tests over actual call recordings.
- Common phrases hit cache on repeat calls.
- Phone numbers, times, and prices sound natural.
- No robotic stage directions, emojis, or markup reach TTS.

## Tests

- Unit tests for pronunciation normalizer.
- Unit tests for cache keys and common phrase warming.
- Golden text tests for TTS sanitizer output.
- Manual listening checklist with saved recordings.
- Added unit tests for phone numbers, prices, times, acronyms, and warmup text preparation.

## Owner Notes

Do not chase "cool" voices. Choose the voice that is clearest over a normal phone call.
