"""Launch-trial hook kept so profile setup has one call site.

The automatic comp-style trial is retired. A new account gets 14 days and 50
minutes only after a Stripe subscription trial or an Apple introductory offer.
Comped accounts are not written here.
"""

from __future__ import annotations

from typing import Any


def maybe_activate_launch_trial(
    supabase: Any,
    user_id: str,
    profile: dict[str, Any],
    *,
    sync_user_plan,
    allow_trial: bool = True,
) -> dict[str, Any]:
    """Return the profile unchanged."""
    del supabase, user_id, sync_user_plan, allow_trial
    return profile
