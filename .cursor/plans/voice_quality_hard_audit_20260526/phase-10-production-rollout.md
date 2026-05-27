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

## Acceptance Criteria

- Voice changes can be turned off without reverting code.
- Monitoring shows real voice quality metrics.
- Launch checklist has measurable pass/fail gates.
- Support/runbook tells an operator exactly what to check when a caller reports silence, delay, or bad booking.

## Tests

- Verify env-driven feature flags.
- Verify health check and voice trace summary after deploy.
- Run call lab before and after VPS deployment.

## Owner Notes

This phase is what turns a demo into a service we can confidently sell.
