---
name: Voice Quality Hard Audit
overview: A 10-phase execution plan to turn Echodesk's voice receptionist from usable MVP quality into fast, natural, reliable production quality.
todos: []
isProject: false
---

# Echodesk Voice Quality Hard Audit

## Executive Summary

The voice system is already real and unusually far along for an MVP: Telnyx answers calls, streams audio to FastAPI, Deepgram transcribes, Grok handles reasoning and tool calls, Google TTS speaks back, and calendar bookings are backed by Google Calendar plus Supabase. The recent live test confirms the core business loop works: a caller can reach the AI receptionist, ask for availability, and get a booked appointment.

The main remaining quality gap is not one single bug. It is the compound effect of startup delay, turn-end detection, LLM/tool latency, TTS synthesis latency, limited call-level metrics, and a few reliability edges that can create awkward silence. To make the voice feel excellent, we need to tune the entire call path as a measured product surface.

This folder defines the execution plan.

## Current Architecture

```text
Telnyx call.initiated
  -> backend/telnyx/voice_webhook.py answers call
  -> call.answered starts bidirectional media stream
  -> backend/voice/handler.py accepts WebSocket
  -> backend/voice/pipeline.py runs turn-taking
  -> Deepgram live STT
  -> deterministic fast paths or Grok tools
  -> /api/voice/calendar for availability and booking
  -> Google Cloud TTS in mu-law 8 kHz
  -> Telnyx media frames back to caller
```

## Hard Audit Findings

### 1. Measurement is present but incomplete

Evidence: `backend/voice/pipeline.py` logs `[BOOKING_LATENCY]` at turn start, calendar tool boundaries, TTS start, and turn end. `backend/voice/tts_facade.py` logs TTS synthesis and chunk sending. This is useful but not yet a full call trace. There is no single per-call timeline artifact that can answer: answer-to-first-audio, caller-speech-end-to-first-assistant-audio, tool latency, synth latency, total silence, barge-in cancellations, or template-vs-LLM path.

Impact: We can improve code, but we cannot prove the voice is "amazing" without p50/p95 metrics and real call traces.

### 2. Startup can feel slow

Evidence: `backend/voice/handler.py` sends initial silence, then `run_voice_pipeline()` sends recording consent and greeting. In `backend/voice/pipeline.py`, consent TTS is awaited before the greeting task is started. TTS cache defaults to `none` in `backend/config.py`, so common phrases can be re-synthesized on every call.

Impact: Even if the pipeline is healthy, callers may hear a delay before the useful greeting. This explains part of the "waited around eight seconds" experience.

### 3. Turn-end latency is deliberately conservative

Evidence: Deepgram is configured with `endpointing=250` and `utterance_end_ms=1000` in `backend/voice/deepgram_client.py`. The pipeline adds `DEBOUNCE_MS=1200` or `DEBOUNCE_MS_FALLBACK=800` in `backend/voice/pipeline_constants.py`.

Impact: A normal caller pause can wait roughly 1-2 seconds before the backend even starts processing. That is safe but not premium-feeling. We need data-driven tuning, not guesswork.

### 4. Deterministic paths exist and should become the default for common intents

Evidence: `backend/voice/pipeline.py` already handles identity, farewells, post-booking replies, availability, booking fast path, slot selection, and unavailable-time replies without relying on full LLM dialogue every time.

Impact: This is the right foundation. The next step is expanding deterministic coverage for the top 30-50 real caller utterances so common flows respond quickly and consistently.

### 5. Calendar/tool calls have high timeout ceilings

Evidence: Grok calls use a 60 second client timeout in `backend/voice/grok_client.py`; calendar tool calls use a 15 second timeout in `backend/voice/calendar_tools.py`.

Impact: The system can remain technically alive while the caller hears too much waiting. Premium voice needs short budgets, quick fallback speech, and graceful recovery.

### 6. TTS quality is solid but not yet tuned like a voice product

Evidence: Google Neural2 presets are available in `backend/voice_presets.py`, with global rate/pitch in `backend/config.py`. TTS generates mu-law 8 kHz directly for telephony in `backend/voice/tts_facade.py`.

Impact: This is stable and cost-aware, but we still need perceptual tuning: voice selection, rate/pitch matrix, caching, pronunciation cleanup, phrase design, and call-recorder listening tests.

### 7. Audio send and interruption behavior need deeper validation

Evidence: `backend/voice/tts_facade.py` chunks mu-law audio and sends chunks in a tight loop. `backend/voice/pipeline.py` cancels pending debounce/Grok on new interim speech, but we do not yet have a complete barge-in test harness proving that callers can interrupt the assistant naturally.

Impact: Even with good words, voice will feel poor if the caller and assistant talk over each other or if audio buffers after an interruption.

### 8. Cleanup and duplicate stream handling have risk edges

Evidence: `backend/voice/handler.py` comments that duplicate connection prevention is disabled. The `stop()` function in `backend/voice/pipeline.py` checks `if dg_task and not grok_task.done()`, which can fail when `grok_task` is `None`; it should check `dg_task`.

Impact: These are not necessarily the cause of the latest live issue, but they are hardening items before serious external testing.

### 9. Booking conversation needs a "human receptionist" script layer

Evidence: The prompt builder contains many booking rules, while `pipeline_templates.py` returns short deterministic booking and availability lines. The split is good, but the final caller experience still needs scenario scripts: greeting, service selection, availability summary, slot selection, unavailable request, booking confirmation, post-booking questions, and calendar failure.

Impact: This is where "usable" becomes "wow, this feels like a trained receptionist."

### 10. We need a real call lab before launch

Evidence: Unit tests cover transcript guards, fast path routing, slot selection, calendar tool contracts, recording, and webhook security. There is no repeatable voice call QA matrix that scores latency, interruption, accuracy, booking success, and audio quality from actual Telnyx calls.

Impact: Launch confidence requires a measured call lab with scripted calls and recordings.

## Target Quality Bar

- Answer-to-first-audible-system-speech: p50 under 2.0s, p95 under 4.0s.
- User speech end to first assistant audio: p50 under 1.2s for deterministic paths, p95 under 3.5s for calendar/tool paths.
- Common identity/farewell/post-booking replies: no LLM, p95 under 1.5s.
- Availability request: pre-ack under 800ms after committed turn, final answer p95 under 4.0s.
- Booking after offered slot: p95 under 3.5s and never silent.
- Silent committed turns: zero.
- Booking correctness: no invented slots, no calendar event without a valid chosen time, no unsupported SMS delivery claims.
- Caller experience: short, warm, confident, no robotic monologues, no repeated "one sec" chains.

## Phase Map

1. [Baseline Measurement and Call Trace](phase-01-baseline-measurement.md)
2. [Startup, Greeting, and First Audio](phase-02-startup-first-audio.md)
3. [STT and Turn Detection Tuning](phase-03-stt-turn-detection.md)
4. [Deterministic Fast Paths and No-Silence Contract](phase-04-deterministic-fast-paths.md)
5. [Calendar Booking Conversation Quality](phase-05-calendar-booking-quality.md)
6. [TTS Voice Quality, Caching, and Pronunciation](phase-06-tts-quality-cache.md)
7. [Barge-In, Interruptions, and Audio Transport](phase-07-barge-in-audio-transport.md)
8. [Prompt, Persona, and Receptionist Presets](phase-08-prompt-persona-presets.md)
9. [Call Lab, QA Matrix, and Regression Harness](phase-09-call-lab-qa.md)
10. [Production Rollout, Monitoring, and Launch Readiness](phase-10-production-rollout.md)

## Execution Rule

Do not optimize blind. Each phase must produce either measured latency improvement, fewer silent/failed turns, better booking correctness, or a recorded/listened call sample that proves the user experience is better.
