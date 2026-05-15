"""Stripe webhook and related routes."""

from __future__ import annotations

import logging
from datetime import datetime

import stripe
from fastapi import Request
from fastapi.responses import JSONResponse

from config import settings
from billing.stripe_sync import (
    mark_subscription_canceled,
    stripe_subscription_status_to_db_status,
    upsert_subscription_from_stripe,
)
from stripe_plans import plan_from_subscription
from supabase_client import create_service_role_client

logger = logging.getLogger(__name__)


def _stripe_metadata_to_dict(metadata) -> dict:
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


async def stripe_webhook_post(request: Request):
    """Handle Stripe webhook events."""
    secret = (settings.stripe_webhook_secret or "").strip()
    if not secret:
        logger.error("[Stripe webhook] STRIPE_WEBHOOK_SECRET not set")
        return JSONResponse({"error": "Missing webhook secret"}, status_code=400)

    body = await request.body()
    sig = request.headers.get("stripe-signature")
    if not sig:
        return JSONResponse({"error": "Missing signature"}, status_code=400)

    stripe.api_key = (settings.stripe_secret_key or "").strip()
    if not stripe.api_key:
        return JSONResponse({"error": "Stripe not configured"}, status_code=503)

    try:
        event = stripe.Webhook.construct_event(body, sig, secret)
    except Exception as e:
        logger.error("[Stripe webhook] Signature verification failed: %s", e)
        return JSONResponse({"error": f"Signature verification failed: {e}"}, status_code=400)

    logger.info("[Stripe webhook] Event received: %s %s", event.type, event.id)
    supabase = create_service_role_client()
    ts = datetime.utcnow().isoformat() + "Z"

    if event.type == "checkout.session.completed":
        session = event.data.object
        metadata = _stripe_metadata_to_dict(getattr(session, "metadata", None))
        user_id = metadata.get("userId") or session.client_reference_id
        email = metadata.get("email") or session.customer_email or (session.customer_details.email if session.customer_details else None)
        customer_id = session.customer if isinstance(session.customer, str) else (session.customer.id if session.customer else None)

        if not customer_id:
            pass
        elif not user_id and email:
            r = supabase.table("users").select("id").eq("email", email).limit(1).execute()
            if r.data and len(r.data) > 0:
                user_id = r.data[0]["id"]

        if user_id:
            updates = {
                "id": user_id,
                "email": email,
                "stripe_customer_id": customer_id,
                "subscription_status": "past_due",
                "updated_at": ts,
            }
            sub_id = session.subscription
            if sub_id:
                sub_obj = sub_id if hasattr(sub_id, "id") else stripe.Subscription.retrieve(sub_id, expand=["items.data.price"])
                updates["stripe_subscription_id"] = sub_obj.id if hasattr(sub_obj, "id") else str(sub_id)
                updates["subscription_status"] = stripe_subscription_status_to_db_status(
                    getattr(sub_obj, "status", None)
                )
                plan = plan_from_subscription(sub_obj)
                if plan:
                    updates["billing_plan"] = plan["billing_plan"]
                    updates["billing_plan_metadata"] = plan.get("billing_plan_metadata")
                    upsert_subscription_from_stripe(
                        supabase, user_id=user_id, stripe_subscription=sub_obj, plan=plan
                    )
            supabase.table("users").upsert(updates, on_conflict="id").execute()
            logger.info("[Stripe webhook] checkout.session.completed: user %s set active", user_id)

    elif event.type in ("customer.subscription.created", "customer.subscription.updated"):
        subscription = event.data.object
        customer_id = subscription.customer if isinstance(subscription.customer, str) else subscription.customer
        r = supabase.table("users").select("id").eq("stripe_customer_id", customer_id).limit(1).execute()
        if r.data and len(r.data) > 0:
            user = r.data[0]
            plan = plan_from_subscription(subscription)
            update = {
                "subscription_status": stripe_subscription_status_to_db_status(subscription.status),
                "stripe_subscription_id": subscription.id,
                "updated_at": ts,
            }
            if plan:
                update["billing_plan"] = plan["billing_plan"]
                update["billing_plan_metadata"] = plan.get("billing_plan_metadata")
                meta = plan.get("billing_plan_metadata") or {}
                included = meta.get("included_minutes", 0)
                overage_cents = int(meta.get("overage_rate_cents", 8))
                ep = supabase.table("user_plans").select("inbound_percent, outbound_percent").eq("user_id", user["id"]).limit(1).execute()
                inbound_pct = 80
                outbound_pct = 20
                if ep.data and len(ep.data) > 0:
                    inbound_pct = ep.data[0].get("inbound_percent") or 80
                    outbound_pct = ep.data[0].get("outbound_percent") or 20
                alloc_in = int((included * inbound_pct) / 100) if plan["billing_plan"] != "subscription_payg" else None
                alloc_out = (included - alloc_in) if alloc_in is not None else None
                supabase.table("user_plans").upsert({
                    "user_id": user["id"],
                    "billing_plan": plan["billing_plan"],
                    "allocated_inbound_minutes": alloc_in,
                    "allocated_outbound_minutes": alloc_out,
                    "inbound_percent": inbound_pct,
                    "outbound_percent": outbound_pct,
                    "overage_rate_cents": overage_cents,
                    "payg_rate_cents": 20,
                    "updated_at": ts,
                }, on_conflict="user_id").execute()
                upsert_subscription_from_stripe(
                    supabase, user_id=user["id"], stripe_subscription=subscription, plan=plan
                )
            supabase.table("users").update(update).eq("id", user["id"]).execute()
            logger.info("[Stripe webhook] customer.subscription.*: user %s status %s", user["id"], subscription.status)

    elif event.type == "customer.subscription.deleted":
        subscription = event.data.object
        customer_id = subscription.customer if isinstance(subscription.customer, str) else subscription.customer
        r = supabase.table("users").select("id").eq("stripe_customer_id", customer_id).limit(1).execute()
        if r.data and len(r.data) > 0:
            user_id = r.data[0]["id"]
            supabase.table("users").update({
                "subscription_status": "canceled",
                "billing_plan": None,
                "billing_plan_metadata": None,
                "stripe_subscription_id": None,
                "updated_at": ts,
            }).eq("id", user_id).execute()
            supabase.table("user_plans").delete().eq("user_id", user_id).execute()
            mark_subscription_canceled(supabase, stripe_subscription_id=subscription.id)
            logger.info("[Stripe webhook] customer.subscription.deleted: user %s", user_id)

    return {"received": True}
