"""Unit tests for public trial-offer remaining-spot math."""

from trial_offer import compute_trial_spots


def test_compute_trial_spots_starts_full() -> None:
    assert compute_trial_spots(total_spots=100, user_count=0, users_baseline=0) == {
        "total_spots": 100,
        "claimed": 0,
        "remaining": 100,
        "user_count": 0,
        "users_baseline": 0,
    }


def test_compute_trial_spots_ignores_baseline_users() -> None:
    out = compute_trial_spots(total_spots=100, user_count=12, users_baseline=10)
    assert out["claimed"] == 2
    assert out["remaining"] == 98


def test_compute_trial_spots_caps_at_zero_remaining() -> None:
    out = compute_trial_spots(total_spots=100, user_count=250, users_baseline=0)
    assert out["claimed"] == 100
    assert out["remaining"] == 0
