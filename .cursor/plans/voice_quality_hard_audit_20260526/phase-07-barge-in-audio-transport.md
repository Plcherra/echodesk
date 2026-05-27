# Phase 07 - Barge-In, Interruptions, and Audio Transport

## Goal

Make interruptions natural and prevent stale assistant audio from fighting with the caller.

## Why This Matters

Humans interrupt receptionists. A premium voice agent must handle that gracefully. If old audio keeps playing after the caller speaks, the system feels fake.

## Current Evidence

- `backend/voice/pipeline.py` cancels debounce and Grok tasks on new interim speech.
- `backend/voice/tts_facade.py` sends all TTS chunks in a tight loop.
- `backend/voice/handler.py` has duplicate WebSocket protection disabled.
- There is no explicit per-utterance audio playback cancellation or media buffer flush contract.

## Implementation Plan

1. Measure whether Telnyx buffers media chunks after caller interruption.
2. Add an assistant utterance id to every TTS send.
3. Track current speaking state:
   - idle
   - synthesizing
   - sending
   - interrupted
4. On caller speech:
   - cancel pending debounce
   - cancel Grok task
   - mark current TTS utterance interrupted
   - stop sending remaining chunks
   - if Telnyx supports clear/flush behavior, use it
5. Validate whether chunk pacing improves interruption behavior:
   - immediate send
   - 100ms pacing
   - 160-200ms telephony pacing
6. Re-enable safe duplicate stream handling or explicitly document why it remains disabled.
7. Fix cleanup edge in pipeline stop logic.

## Acceptance Criteria

- Caller can interrupt a long assistant response and get a new response path.
- No stale TTS continues for more than 500ms after interruption, if Telnyx transport allows it.
- Duplicate WebSocket streams cannot create conflicting assistant audio.
- Pipeline cleanup does not throw on normal disconnect.

## Tests

- Unit test TTS cancellation state.
- Fake WebSocket test for duplicate call_sid handling.
- Regression test for `pipeline.stop()` when `grok_task` is `None`.
- Manual call test: interrupt greeting, interrupt availability answer, interrupt booking confirmation.

## Owner Notes

This is a quality multiplier. It is also easy to break, so keep it behind metrics and tests.
