"""Launch trial inventory math (pure; no I/O)."""

from __future__ import annotations


def compute_trial_spots(
    *,
    total_spots: int,
    user_count: int,
    users_baseline: int = 0,
) -> dict[str, int]:
    """Derive claimed/remaining from signup count.

    Spots are the first N customer accounts. ``users_baseline`` ignores accounts
    that already existed before the offer went live (team/test users).
    """
    total = max(0, total_spots)
    baseline = max(0, users_baseline)
    claimed = max(0, user_count - baseline)
    if claimed > total:
        claimed = total
    remaining = max(0, total - claimed)
    return {
        "total_spots": total,
        "claimed": claimed,
        "remaining": remaining,
        "user_count": max(0, user_count),
        "users_baseline": baseline,
    }
