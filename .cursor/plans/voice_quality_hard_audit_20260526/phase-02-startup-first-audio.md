# Phase 02 - Startup, Greeting, and First Audio

## Goal

Make the first seconds of the call feel immediate, confident, and professional.

## Why This Matters

The caller's first impression is formed before the AI understands anything. If they hear silence, a delayed consent phrase, or a slow greeting, the product feels unreliable even if later booking works.

## Current Evidence

- `backend/voice/handler.py` sends initial silence and then starts the voice pipeline.
- `backend/voice/pipeline.py` awaits the recording consent TTS before launching the greeting task.
- `backend/config.py` defaults `tts_cache_backend` to `none`, so common startup phrases may be synthesized every call.
- Prompt data is pre-cached during `call.initiated`, which is good and should be preserved.

## Implementation Plan

1. Measure answer-to-WebSocket, WebSocket-to-consent, consent-to-greeting, and greeting-to-first-caller-transcript.
2. Enable and validate a production TTS cache for common startup phrases:
   - consent phrase
   - default greeting
   - configured receptionist greeting
   - "Checking now."
   - "Got it. Booking now."
   - "One sec."
3. Consider combining consent and greeting into one clean startup utterance when legally acceptable:
   - "This call may be recorded. Thanks for calling, this is Eve. How can I help?"
4. If consent must remain separate, pre-synthesize consent and greeting concurrently before sending.
5. Add startup failure fallback:
   - If greeting TTS fails, play backup voice.
   - If backup fails, log clear critical error and avoid pretending the stream is healthy.
6. Add startup script variants for businesses:
   - professional
   - warm
   - concierge
   - healthcare/legal conservative

## Acceptance Criteria

- First audible system speech p50 under 2.0 seconds after answer.
- Greeting begins no later than 700ms after consent audio finishes.
- Startup phrases hit TTS cache in repeat calls.
- No call starts with more than 4 seconds of silence unless Telnyx stream connection itself is delayed and trace proves it.

## Tests

- Unit test startup phrase cache keys.
- Add integration-style test with fake TTS to assert consent and greeting ordering.
- Run live call sample set and save trace summaries.

## Owner Notes

This phase should likely create the most obvious perceived quality improvement.
