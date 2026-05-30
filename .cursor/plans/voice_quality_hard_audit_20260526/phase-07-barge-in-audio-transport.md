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
- Phase 07 slice 1 adds explicit assistant utterance state, chunk-send interruption checks, and Telnyx `clear` on caller speech.
- Phase 07 slice 1 re-enables duplicate stream replacement and fixes the `pipeline.stop()` cleanup condition.

## Implementation Plan

1. Measure whether Telnyx buffers media chunks after caller interruption.
2. Add an assistant utterance id to every TTS send.
   - Status: slice 1 complete via `tts_playback_state.active_utterance_id`.
3. Track current speaking state:
   - idle
   - synthesizing
   - sending
   - interrupted
   - Status: slice 1 complete for TTS synthesis/send lifecycle.
4. On caller speech:
   - cancel pending debounce
   - cancel Grok task
   - mark current TTS utterance interrupted
   - stop sending remaining chunks
   - if Telnyx supports clear/flush behavior, use it
   - Status: slice 1 complete; caller speech marks TTS interrupted and sends a Telnyx `clear` event.
5. Validate whether chunk pacing improves interruption behavior:
   - immediate send
   - 100ms pacing
   - 160-200ms telephony pacing
6. Re-enable safe duplicate stream handling or explicitly document why it remains disabled.
   - Status: slice 1 replaces an existing active stream for the same `call_sid`.
7. Fix cleanup edge in pipeline stop logic.
   - Status: slice 1 complete; `dg_task` cancellation now checks `dg_task.done()`.

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
- Added regression tests for chunk-send interruption and `pipeline.stop()` with no Grok task.

## Owner Notes

This is a quality multiplier. It is also easy to break, so keep it behind metrics and tests.
