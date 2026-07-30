"""Public unauthenticated marketing endpoints."""

from __future__ import annotations

import logging
import os
from typing import Any

from fastapi import APIRouter
from fastapi.responses import JSONResponse

from supabase_client import create_service_role_client
from trial_offer import compute_trial_spots

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/public", tags=["public"])

DEFAULT_TRIAL_TOTAL_SPOTS = 100


def _env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        logger.warning("Invalid %s=%r; using default %s", name, raw, default)
        return default


def _count_users(supabase: Any) -> int:
    cutoff = (os.environ.get("TRIAL_LAUNCH_CUTOFF") or "").strip()
    query = supabase.table("users").select("id", count="exact")
    if cutoff:
        query = query.gte("created_at", cutoff)
    res = query.execute()
    count = getattr(res, "count", None)
    if count is None and isinstance(res, dict):
        count = res.get("count")
    if count is None:
        data = getattr(res, "data", None)
        if data is None and isinstance(res, dict):
            data = res.get("data")
        count = len(data or [])
    return int(count or 0)


@router.get("/trial-offer")
async def trial_offer() -> JSONResponse:
    """Live trial inventory for marketing pages (no auth).

    Counts customer accounts toward the first-100 launch trial. Set
    TRIAL_USERS_BASELINE to the current users count when you flip the offer on,
    or TRIAL_LAUNCH_CUTOFF (ISO timestamp) to only count signups after launch.
    """
    total = _env_int("TRIAL_TOTAL_SPOTS", DEFAULT_TRIAL_TOTAL_SPOTS)
    baseline = _env_int("TRIAL_USERS_BASELINE", 0)
    try:
        supabase = create_service_role_client()
        user_count = _count_users(supabase)
        payload = compute_trial_spots(
            total_spots=total,
            user_count=user_count,
            users_baseline=baseline,
        )
    except Exception as e:
        logger.warning("trial-offer count failed: %s", e)
        # Fail soft for marketing: show full inventory rather than a broken page.
        payload = compute_trial_spots(
            total_spots=total,
            user_count=baseline,
            users_baseline=baseline,
        )
        payload["degraded"] = True

    payload.update(
        {
            "trial_days": 14,
            "included_minutes": 60,
            "headline": f"14-day free trial for the first {payload['total_spots']} customers",
        }
    )
    return JSONResponse(
        content=payload,
        headers={"Cache-Control": "public, max-age=30"},
    )
