# Phase 09 - Call Lab, QA Matrix, and Regression Harness

## Goal

Create a repeatable call testing lab that proves voice quality before every launch push.

## Why This Matters

Unit tests prove code paths. Real phone calls prove product quality. Echodesk needs both.

## Current Evidence

- There are useful backend tests for guardrails, slot selection, calendar tools, recording, SMS, and webhooks.
- There is no formal scored live-call QA matrix.
- The mobile app shows recordings and call history, so QA artifacts are already accessible.

## Implementation Plan

1. Create a call script matrix:
   - basic greeting
   - identity question
   - tomorrow availability
   - specific unavailable time
   - slot selection
   - successful booking
   - caller interruption
   - calendar disconnected
   - tool timeout
   - goodbye
2. Score each call on:
   - first audio latency
   - turn latency
   - correctness
   - naturalness
   - interruption handling
   - booking outcome
   - recording/call log outcome
3. Save call recordings and trace summaries per run.
4. Add a `scripts/voice-call-lab-report` parser that creates Markdown summaries.
5. Define pass/fail gates for internal beta.

## Acceptance Criteria

- A full QA run covers at least 20 scripted calls.
- Every run produces a Markdown report with metrics and notes.
- Failures identify the phase/category responsible.
- No release proceeds with silent committed turns or invented availability.

## Tests

- Unit test call lab parser.
- Add fixture logs for a successful and failed call.
- Keep current pytest suite as the code-level gate.

## Owner Notes

Use your own phone tests, but make the results repeatable enough that another tester can reproduce them.
