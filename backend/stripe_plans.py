"""Stripe plan mapping: price ID -> billing_plan. Option A: Starter / Growth / Pro + flat overage."""

from __future__ import annotations

import os
from typing import Any

# Option A: monthly fee matches Stripe recurring price; included minutes; overage $0.08/min (8 cents)
PLAN_DEFS = [
    {
        "id": "starter",
        "env_key": "STRIPE_PRICE_STARTER",
        "included_minutes": 300,
        "monthly_fee_cents": 6900,
        "overage_rate_cents": 8,
        "per_minute_cents": 8,
        "billing_plan_id": "subscription_starter",
    },
    {
        "id": "growth",
        "env_key": "STRIPE_PRICE_GROWTH",
        "included_minutes": 800,
        "monthly_fee_cents": 5900,
        "overage_rate_cents": 8,
        "per_minute_cents": 8,
        "billing_plan_id": "subscription_growth",
    },
    {
        "id": "pro",
        "env_key": "STRIPE_PRICE_PRO",
        "included_minutes": 1800,
        "monthly_fee_cents": 14900,
        "overage_rate_cents": 8,
        "per_minute_cents": 8,
        "billing_plan_id": "subscription_pro",
    },
    # Legacy / special
    {
        "id": "business",
        "env_key": "STRIPE_PRICE_BUSINESS",
        "included_minutes": 1500,
        "monthly_fee_cents": 24900,
        "overage_rate_cents": 8,
        "per_minute_cents": 25,
        "billing_plan_id": "subscription_business",
    },
    {
        "id": "enterprise",
        "env_key": "STRIPE_PRICE_ENTERPRISE",
        "included_minutes": 5000,
        "monthly_fee_cents": 49900,
        "overage_rate_cents": 8,
        "per_minute_cents": 20,
        "billing_plan_id": "subscription_enterprise",
    },
    {
        "id": "dev_test",
        "env_key": "STRIPE_PRICE_DEV_TEST",
        "included_minutes": 50,
        "monthly_fee_cents": 100,
        "overage_rate_cents": 8,
        "per_minute_cents": 20,
        "billing_plan_id": "subscription_dev_test",
    },
    {
        "id": "payg",
        "env_key": "STRIPE_PRICE_PAYG",
        "included_minutes": 0,
        "monthly_fee_cents": 0,
        "overage_rate_cents": 8,
        "per_minute_cents": 20,
        "billing_plan_id": "subscription_payg",
    },
]


def _stripe_metadata_to_dict(metadata: Any) -> dict[str, Any]:
    if not metadata:
        return {}
    if isinstance(metadata, dict):
        return metadata
    try:
        return dict(metadata)
    except Exception:
        to_dict = getattr(metadata, "to_dict", None)
        if callable(to_dict):
            try:
                return to_dict()
            except Exception:
                return {}
    return {}


def _get_price_to_plan_map() -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for p in PLAN_DEFS:
        price_id = os.environ.get(p["env_key"], "").strip()
        if price_id:
            out[price_id] = {
                "billing_plan": p["billing_plan_id"],
                "plan_code": p["id"],
                "billing_plan_metadata": {
                    "included_minutes": p["included_minutes"],
                    "monthly_fee_cents": p["monthly_fee_cents"],
                    "per_minute_cents": p["per_minute_cents"],
                    "overage_rate_cents": p["overage_rate_cents"],
                    "payg_rate_cents": 20,
                    "phone_extra_cents": 0,
                },
            }
    return out


def plan_from_subscription(subscription: Any) -> dict[str, Any] | None:
    """Resolve billing_plan and metadata from a Stripe subscription."""
    items = getattr(subscription, "items", None) or []
    data = getattr(items, "data", []) if hasattr(items, "data") else []
    price = data[0].price if data else None
    if not price:
        return None
    price_id = price.id if hasattr(price, "id") else str(price)
    if isinstance(price_id, str) and not price_id:
        return None

    m = _get_price_to_plan_map()
    if price_id in m:
        return m[price_id]

    meta = _stripe_metadata_to_dict(getattr(price, "metadata", None))
    plan = meta.get("plan")
    if not plan:
        return None
    result: dict[str, Any] = {"billing_plan": str(plan), "billing_plan_metadata": {}, "plan_code": meta.get("plan_code")}
    if meta.get("included_minutes") is not None:
        try:
            result["billing_plan_metadata"]["included_minutes"] = int(meta["included_minutes"])
        except (ValueError, TypeError):
            pass
    if meta.get("monthly_fee_cents") is not None:
        try:
            result["billing_plan_metadata"]["monthly_fee_cents"] = int(meta["monthly_fee_cents"])
        except (ValueError, TypeError):
            pass
    if meta.get("per_minute_cents") is not None:
        try:
            result["billing_plan_metadata"]["per_minute_cents"] = int(meta["per_minute_cents"])
        except (ValueError, TypeError):
            pass
    if meta.get("overage_rate_cents") is not None:
        try:
            result["billing_plan_metadata"]["overage_rate_cents"] = int(meta["overage_rate_cents"])
        except (ValueError, TypeError):
            pass
    return result


def get_price_id_for_plan_id(plan_id: str) -> str | None:
    """Resolve Stripe price ID from plan id (e.g. starter, growth, pro)."""
    for p in PLAN_DEFS:
        if p["id"] == plan_id:
            price_id = os.environ.get(p["env_key"], "").strip()
            if price_id:
                return price_id
            if plan_id == "starter":
                fallback = os.environ.get("STRIPE_PRICE_ID", "").strip()
                if fallback:
                    return fallback
    return None
