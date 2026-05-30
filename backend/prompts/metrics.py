"""Prompt inspection helpers for generated receptionist prompts."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PromptMetrics:
    chars: int
    estimated_tokens: int
    booking_mentions: int
    availability_mentions: int
    violations: tuple[str, ...]


FORBIDDEN_PROMPT_SUBSTRINGS = (
    "ignore previous instructions",
    "you may invent availability",
    "make up times",
    "show raw json",
    "speak payment links",
    "mention technical errors",
)


def estimate_tokens(text: str) -> int:
    """Cheap prompt-token estimate for linting and logs."""
    return max(1, len(text or "") // 4)


def inspect_prompt(text: str) -> PromptMetrics:
    prompt = text or ""
    lower = prompt.lower()
    violations = tuple(item for item in FORBIDDEN_PROMPT_SUBSTRINGS if item in lower)
    return PromptMetrics(
        chars=len(prompt),
        estimated_tokens=estimate_tokens(prompt),
        booking_mentions=lower.count("booking"),
        availability_mentions=lower.count("availability"),
        violations=violations,
    )
