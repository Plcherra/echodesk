# Phase 03 - STT and Turn Detection Tuning

## Goal

Reduce dead air after the caller stops speaking while keeping accuracy and avoiding premature interruption.

## Why This Matters

Voice quality lives in the pauses. A technically correct answer that starts two seconds late feels worse than a shorter answer that starts naturally.

## Current Evidence

- Deepgram live parameters are hard-coded in `backend/voice/deepgram_client.py`:
  - `endpointing=250`
  - `utterance_end_ms=1000`
  - `interim_results=true`
  - `vad_events=true`
- Pipeline debounce adds `800ms` for short utterances and `1200ms` by default in `backend/voice/pipeline_constants.py`.
- Immediate dispatch exists for clear intent, farewell, and short whitelist paths.
- Phase 3 first implementation slice landed:
  - Deepgram `endpointing` and `utterance_end_ms` are env-tunable with conservative caps.
  - Pipeline debounce values are env-tunable with conservative caps.
  - Commit traces include the triggering Deepgram signal source.
  - Common short booking follow-ups now dispatch immediately.

## Implementation Plan

1. Make Deepgram endpointing and utterance-end settings configurable via env. **Done.**
   - `DEEPGRAM_ENDPOINTING_MS`, default `250`, capped `100..1000`.
   - `DEEPGRAM_UTTERANCE_END_MS`, default `1000`, capped `300..2000`.
2. Make debounce constants configurable but capped to safe ranges. **Done.**
   - `VOICE_DEBOUNCE_MS`, default `1200`, capped `300..2000`.
   - `VOICE_DEBOUNCE_FALLBACK_MS`, default `800`, capped `150..1200`.
3. Run a tuning matrix:
   - endpointing: 150, 200, 250, 350
   - utterance_end_ms: 500, 700, 1000
   - debounce default: 600, 800, 1000, 1200
   - debounce fallback: 350, 500, 700, 800
4. Add trace fields for:
   - final transcript timestamp
   - speech_final timestamp
   - utterance_end timestamp
   - commit timestamp
   - dispatch timestamp
   - commit trigger source
5. Expand immediate intent detection for:
   - "do you have tomorrow morning"
   - "can you do 9"
   - "book that"
   - "the first one"
   - "yes that works"
   **Done for this first pattern set.**
6. Keep a false-start test suite so we do not answer while the caller is mid-sentence.
   **Started.** Current tests keep phrases like "can you", "tomorrow at", and "I need" in wait mode.

## Acceptance Criteria

- User speech end to commit p50 below 600ms for common intents.
- No increase in partial-turn mistakes across test scripts.
- Short slot selections do not wait more than 700ms before processing.
- Incomplete phrases like "tomorrow at..." still wait for completion.

## Tests

- Add unit tests for new immediate-intent patterns.
- Add table-driven tests for incomplete transcripts vs complete booking intents.
- Add a local synthetic Deepgram event sequence test for final/interim/utterance-end ordering.

## Owner Notes

Do not tune this by feel alone. Record call samples before and after.
