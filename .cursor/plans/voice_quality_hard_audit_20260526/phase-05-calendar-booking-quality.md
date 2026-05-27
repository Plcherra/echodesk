# Phase 05 - Calendar Booking Conversation Quality

## Goal

Make scheduling feel like a great human receptionist: fast, precise, and never confused about slots.

## Why This Matters

The main business value is booking. A slow or unclear booking conversation hurts trust more than almost any UI issue.

## Current Evidence

- `backend/voice/slot_selection.py` safely maps caller selections to last-offered slots.
- `backend/voice/pipeline_templates.py` avoids inventing availability and gives bucket-first replies.
- `backend/calendar_api/calendar_handler.py` enforces service-first behavior when services exist.
- The live test booked an appointment, but the "9 AM" attempt previously failed to get a clear reply.

## Implementation Plan

1. Define the canonical booking script:
   - service or generic appointment
   - date
   - availability
   - slot choice
   - confirmation
   - booking result
   - post-booking instructions
2. Improve unavailable-slot behavior:
   - if caller asks for a specific unavailable time, speak the closest available periods or slots.
   - if no exact time is available, do not silently fall through to LLM.
3. Add "one question at a time" recovery:
   - missing date
   - missing time
   - missing service
   - missing name if required
4. Add tool time budgets:
   - availability soft budget
   - booking soft budget
   - fallback phrase if exceeded
5. Review service/generic behavior:
   - avoid asking for unnecessary details when no services are configured.
   - avoid booking generic appointments too eagerly when date/time are ambiguous.
6. Add booking transcript examples to tests.

## Acceptance Criteria

- Slot choice after offered availability books or replies unavailable within p95 3.5s.
- The assistant never offers a time outside `exact_slots` or `suggested_slots`.
- Booking confirmation is one short sentence unless the caller asks for details.
- Failed calendar/tool calls produce a clear spoken recovery path.

## Tests

- Add tests for specific unavailable time after bucket availability.
- Add tests for first/second/third slot, daypart choice, and "yes that works."
- Add timeout simulation tests for calendar tool.
- Add transcript scenario tests for the full booking flow.

## Owner Notes

This is the highest business-value phase after measurement and startup.
