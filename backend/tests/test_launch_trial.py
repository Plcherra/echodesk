"""Unit tests for launch trial eligibility helpers."""

from __future__ import annotations

from trial_offer import compute_trial_spots


def test_launch_trial_spots_available_for_early_signups() -> None:
    spots = compute_trial_spots(total_spots=100, user_count=1, users_baseline=0)
    assert spots["remaining"] == 99
    assert spots["claimed"] == 1


def test_launch_trial_spots_exhausted() -> None:
    spots = compute_trial_spots(total_spots=100, user_count=150, users_baseline=0)
    assert spots["remaining"] == 0
    assert spots["claimed"] == 100
