# Phase 04 - Deterministic Fast Paths and No-Silence Contract

## Goal

Move common caller turns away from LLM latency and guarantee every committed turn produces audio or an explicit terminal skip.

## Why This Matters

The best live voice systems are not "LLM for everything." They are deterministic for obvious actions and flexible only when needed. This makes them faster, safer, and less awkward.

## Current Evidence

- Identity, farewell, post-booking, availability, slot selection, and unavailable-time replies already have deterministic branches.
- `docs/ops/RUNBOOK.md` defines the no-silence invariant.
- `backend/tests/test_voice_pipeline_guardrails.py` and related tests protect several fast-path behaviors.

## Implementation Plan

1. Create a top-utterance map from real call transcripts and manual test scripts.
2. Add deterministic handlers for the top cases:
   - greeting/hello
   - "what's your name?"
   - "what do you have tomorrow?"
   - "do you have 9 AM?"
   - "book me for 9"
   - "the first one"
   - "yes that works"
   - "anything else?"
   - "can you repeat that?"
   - goodbye/thanks
3. Add a single `DeterministicTurnResult` object with:
   - `handled`
   - `reply`
   - `tool_name`
   - `tool_args`
   - `reason`
   - `requires_llm_fallback`
4. Replace scattered deterministic checks with a clear ordered router.
5. Add a no-silence test that verifies every deterministic and fallback branch either speaks or logs terminal skip.
6. Add failure-specific apologies:
   - calendar unavailable
   - booking failed
   - tool timeout
   - TTS failure

## Acceptance Criteria

- Top 20 scripted user turns avoid Grok unless ambiguity requires it.
- Any committed turn has exactly one outcome: spoken response, queued response, cancelled response, or terminal skip.
- "Do you have 9 AM?" never goes silent; it either offers availability, says unavailable, or asks one clarifying question.

## Tests

- Table-driven tests for deterministic turn router.
- Regression test for the user's reported scenario:
  - ask tomorrow slots
  - user asks/book 9 AM
  - system replies or books, never silent
- Keep existing voice guardrail tests passing.

## Owner Notes

This phase is where the assistant starts feeling trained instead of generated.
