# Phase 08 - Prompt, Persona, and Receptionist Presets

## Goal

Make each receptionist sound intentional: concise, warm, business-aware, and not over-prompted.

## Why This Matters

Prompting affects the long-tail calls that deterministic routes do not cover. The current prompt is comprehensive, but phone voice quality rewards compact, prioritized instructions.

## Current Evidence

- `backend/prompts/builder.py` builds a detailed prompt with identity, memory, tone, booking rules, service-first logic, location handling, recovery, and post-booking guidance.
- `VOICE_OUTPUT_INSTRUCTIONS` blocks stage directions and non-spoken text.
- Mobile exposes voice presets, but persona style and voice selection are not deeply coupled.

## Implementation Plan

1. Split prompt into layers:
   - invariant system rules
   - business facts
   - booking procedure
   - persona/tone
   - emergency recovery
2. Make prompt compactness measurable:
   - token estimate
   - number of conflicting/repeated booking instructions
   - max response style rules
3. Create receptionist personas:
   - Professional office
   - Warm local service
   - Premium concierge
   - Healthcare/legal conservative
   - Fitness/events upbeat
4. Pair each persona with:
   - voice preset
   - greeting style
   - recovery phrases
   - appointment confirmation style
5. Add prompt snapshot tests so changes are intentional.
6. Add "forbidden spoken outputs" tests:
   - "smiles"
   - markdown
   - raw JSON
   - tool metadata
   - payment link content

## Acceptance Criteria

- LLM fallback responses stay under 2 short sentences unless caller asks for details.
- Persona changes are audible and useful without changing core safety rules.
- The generated prompt is easier to inspect and less repetitive.
- Custom receptionist instructions cannot override no-invented-slots and no-technical-errors rules.

## Tests

- Snapshot tests for generated prompts with services/no services.
- Prompt lint tests for duplicated contradictory instructions.
- LLM-response sanitizer tests.
- Manual listening tests for each persona.

## Owner Notes

This phase should happen after deterministic router improvements, so the prompt only handles what it should handle.

## Phase 8 Implementation Status

- Added reusable receptionist persona presets tied to the existing voice preset keys.
- Compact generated prompts now include persona style, recovery style, and confirmation style while preserving invariant booking safety rules.
- Custom `system_prompt` values are wrapped with non-negotiable voice safety guardrails so business-provided instructions cannot override no-invented-availability or no-technical-errors behavior.
- Added prompt metrics for compactness and repetition tracking in receptionist config logs.
- Added tests for persona style variation, prompt compactness, custom prompt guardrails, voice preset inference, and spoken-output artifact rules.
