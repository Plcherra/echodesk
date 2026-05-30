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

## QA Run 1 - 2026-05-30 Phone Recording

Recording: `/Users/pedromartins/Downloads/75d6b9e0-5c6a-11f1-8a4b-02420aef96a1-1780174777117552.mp3`

Audio facts:

- Duration: 76.54 seconds.
- Format: mono MP3, 11.025 kHz, 32 kbps.
- Rough local transcript is approximate because this is a compressed phone recording.

Approximate transcript:

> This call may be recorded for quality and training purposes. By continuing, the caller consents to recording. Hello, thanks for calling. How can I help you today?
> Caller: Hi, do you have any ...
> Assistant: How can I help ...
> Assistant: What works best for you?
> Caller: Do you have 2:00 PM?
> Assistant: Sure, which day should I check for 2 PM?
> Caller: Tomorrow.
> Assistant: I have morning and afternoon ...
> Assistant: Yes, tomorrow at 2:00 PM is available.
> Caller: 9:00 AM.
> Assistant: I don't see 9:00 AM in the openings I found. I have afternoon openings. What works best?
> Caller: Thanks.

Scores:

| Category | Score | Notes |
| --- | ---: | --- |
| First audio latency | Pass | Greeting starts quickly enough for a phone call. |
| Turn latency | Pass | Responses feel responsive. |
| Correctness | Needs review | Exact 2 PM answer was good, but the 9 AM follow-up response was generic instead of offering exact available alternatives. |
| Naturalness | 7/10 | Clear and usable, but the assistant repeats broad availability language after exact-time turns. |
| Interruption handling | Needs more samples | The early caller interruption overlaps the greeting; assistant recovered, but not enough data for a firm score. |
| Booking outcome | Not tested | Call ended before booking confirmation. |
| Recording/call log | Pass | Recording was available for review. |

Findings:

- Keep: startup speed and exact-time answer for "tomorrow at 2 PM" were good.
- Improve: when a caller switches to another exact time, answer with a direct yes/no and exact alternatives, not broad "morning/afternoon" language.
- Improve: after asking "Which day should I check for 2 PM?" and receiving "tomorrow", the next reply should be only the exact result when an exact time was requested.

Recommended follow-up:

- Add a call-lab parser/report script so recordings, voice traces, and manual scores land in one Markdown artifact.
- Add another live test where the caller asks: "Do you have tomorrow at 2?", then "What about 9?", then chooses a suggested exact slot.
