"""Apple auto-renewable product catalog.

Minute amounts are the Apple IAP entitlements. They are intentionally separate
from the Stripe prices and included minutes in stripe_plans.py. Prices are
never stored here; the iOS app shows the localized price from StoreKit.
"""

from __future__ import annotations

from typing import Any


def apple_product_catalog() -> dict[str, dict[str, Any]]:
    """Map App Store product id -> plan. Product ids come from the environment."""
    from config import settings

    rows = (
        (
            "starter",
            "Starter",
            settings.apple_iap_product_starter,
            250,
        ),
        (
            "growth",
            "Growth",
            settings.apple_iap_product_growth,
            750,
        ),
        (
            "business",
            "Business",
            settings.apple_iap_product_business,
            1500,
        ),
    )
    catalog: dict[str, dict[str, Any]] = {}
    for plan_id, name, product_id, minutes in rows:
        pid = (product_id or "").strip()
        if not pid:
            continue
        catalog[pid] = {
            "plan_id": plan_id,
            "name": name,
            "product_id": pid,
            "included_minutes": int(minutes),
            "billing_plan": f"subscription_{plan_id}",
            "duration": "P1M",
        }
    return catalog


def plan_for_product_id(product_id: str | None) -> dict[str, Any] | None:
    if not product_id:
        return None
    return apple_product_catalog().get(str(product_id).strip())
