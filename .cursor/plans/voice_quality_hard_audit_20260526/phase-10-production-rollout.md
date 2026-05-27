# Phase 10 - Production Rollout, Monitoring, and Launch Readiness

## Goal

Roll out voice improvements safely, with monitoring that catches regressions before customers do.

## Why This Matters

Voice is a trust surface. One bad call can feel more damaging than a small UI bug. Production needs tight observability and controlled rollout.

## Current Evidence

- Health endpoint exists.
- Runbook documents voice invariants and operational checks.
- Backend deployment uses systemd/Nginx/VPS assets.
- There is no explicit voice-quality dashboard or rollout gate.

## Implementation Plan

1. Add voice quality metrics:
   - answer-to-first-audio
   - turn-end-to-first-audio
   - calendar tool duration
   - Grok duration
   - TTS synth duration
   - silent turn count
   - TTS failure count
   - call abandonment before greeting
2. Add daily/weekly QA report.
3. Add feature flags for risky tuning:
   - debounce settings
   - endpointing settings
   - TTS pacing
   - deterministic router version
   - prompt template version
4. Roll out in stages:
   - local fake tests
   - one receptionist dev line
   - Pedro test line
   - first friendly customer
   - all beta customers
5. Create rollback plan for each phase.
6. Define launch gate:
   - no 502 health failures
   - no silent turn regressions
   - call lab passing
   - 10DLC/SMS limitations understood and product copy truthful
7. Prepare the next product-quality track: customer memory.
   - Treat memory as the natural follow-up once voice latency and booking accuracy are stable.
   - Start with business-scoped customer memory, not a broad personal-assistant memory system.
   - Key memories by business/receptionist plus normalized caller phone.
   - Remember only booking-relevant facts such as caller name, preferred time windows, preferred service, usual location, last appointment, and explicit do-not-contact or sensitivity notes.
   - Use a conservative prompt injection summary at call start, for example: "Returning caller: John. Usually books afternoon haircut appointments."
   - Extract/update memories after the call from transcript and booking outcome, not during the live audio path.
   - Add review, edit, delete, and "forget this caller" controls before broad launch.

## Acceptance Criteria

- Voice changes can be turned off without reverting code.
- Monitoring shows real voice quality metrics.
- Launch checklist has measurable pass/fail gates.
- Support/runbook tells an operator exactly what to check when a caller reports silence, delay, or bad booking.
- Launch plan includes a clear handoff into a customer-memory MVP with privacy and review requirements.

## Tests

- Verify env-driven feature flags.
- Verify health check and voice trace summary after deploy.
- Run call lab before and after VPS deployment.

## Owner Notes

This phase is what turns a demo into a service we can confidently sell.

Once this phase is green, the recommended next build track is **Customer Memory MVP**:

1. Add customer and customer-memory tables scoped to each business/receptionist.
2. Lookup a caller by phone at call start and inject a short, safe memory summary.
3. Save confirmed booking preferences and caller identity after successful calls.
4. Add post-call extraction for durable facts from transcripts.
5. Add mobile/admin controls to view, correct, delete, and forget caller memory.

The goal is the lightweight, high-trust experience: "Hi John, good to hear from you again. Are you looking to book your usual afternoon appointment?"
