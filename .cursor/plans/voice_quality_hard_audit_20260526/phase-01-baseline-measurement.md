# Phase 01 - Baseline Measurement and Call Trace

## Goal

Build a reliable measurement layer before tuning. We need to know exactly where every second goes in a live call.

## Why This Matters

The current logs contain useful markers, but they are scattered across Telnyx webhook handling, WebSocket setup, Deepgram messages, pipeline dispatch, calendar tools, Grok, TTS synthesis, and media send. Without a unified call timeline, every voice tuning change is half science and half guess.

## Current Evidence

- `backend/voice/pipeline.py` logs `[TURN_GUARD]`, `[CALL_DIAG]`, and `[BOOKING_LATENCY]`.
- `backend/voice/tts_facade.py` logs TTS synthesis and chunk counts.
- `backend/telnyx/voice_webhook.py` logs call answer, stream start, recording start, and call log updates.
- No per-call timeline file, summary table, or p50/p95 metrics exist.

## Implementation Plan

1. Add a `VoiceTrace` helper keyed by `call_control_id`.
2. Capture monotonic timestamps for:
   - webhook received
   - answer request sent
   - answer accepted
   - streaming start sent
   - WebSocket accepted
   - Deepgram connected
   - consent TTS start/end
   - greeting TTS start/end
   - first inbound audio
   - first final transcript
   - utterance end
   - commit enqueued
   - first assistant audio per turn
   - Grok request/response
   - calendar tool request/response
   - TTS synth start/end
   - media chunks sent
3. Emit one structured JSON summary at call end.
4. Add a script that parses recent logs into a call timeline table.
5. Store local samples in ignored `artifacts/voice-traces/` for development.

## Acceptance Criteria

- A single call can be summarized into a timeline without manual grep.
- The summary includes at least answer-to-first-audio and turn-end-to-first-audio.
- We can compare before/after p50/p95 over at least 10 live test calls.

## Tests

- Unit test the `VoiceTrace` event ordering and duration calculations.
- Add a parser fixture with representative logs.
- Run existing voice tests to confirm logging changes do not alter behavior.

## Owner Notes

This phase should land before any aggressive debounce/STT tuning. It gives us the scoreboard.

## Implementation Notes

Status: implemented on 2026-05-27.

- Runtime trace helper: `backend/voice/trace.py`
- Log parser: `scripts/voice_trace_report.py`
- Unit coverage: `backend/tests/test_voice_trace.py`

To inspect live-call timing after a backend run, scan logs for `[VOICE_TRACE] summary` or pipe logs into:

```bash
python scripts/voice_trace_report.py /path/to/backend.log
```

The most important first-pass metrics are:

- `webhook_to_first_assistant_audio_ms`
- `first_inbound_audio_to_first_final_transcript_ms`
- per-turn `commit_to_first_audio_ms`
- per-turn `grok_ms`
- per-turn `calendar_tool_ms`
