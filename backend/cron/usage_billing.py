"""PAYG and overage billing. Run on 1st of month before reset-usage."""

from __future__ import annotations

import logging
from datetime import date, datetime
from typing import Any

import stripe

from billing.invoicing import compute_overage_minutes
from billing.subscriptions import get_active_subscription
from stripe_plans import DEFAULT_OVERAGE_RATE_CENTS, get_overage_price_id
from supabase_client import create_service_role_client

logger = logging.getLogger(__name__)
MIN_INVOICE_CENTS = 500
MIN_OPTION_A_OVERAGE_CENTS = 50


def _create_overage_invoice_item(
    stripe_mod: Any,
    *,
    customer_id: str,
    invoice_id: str,
    overage_minutes: float,
    rate_cents: int,
    description: str,
) -> None:
    """Attach overage to an invoice.

    Prefer STRIPE_PRICE_OVERAGE + quantity when set (standard per-unit price at
    $0.20/min). Fall back to a raw amount line item so billing still works if
    the overage price is metered/incompatible with InvoiceItem price=.
    """
    qty = max(1, int(round(overage_minutes))) if overage_minutes > 0 else 0
    if qty <= 0:
        return
    price_id = get_overage_price_id()
    if price_id:
        try:
            stripe_mod.InvoiceItem.create(
                customer=customer_id,
                price=price_id,
                quantity=qty,
                description=description,
                invoice=invoice_id,
            )
            return
        except Exception as e:
            logger.warning(
                "[usageBilling] STRIPE_PRICE_OVERAGE failed (%s); using amount fallback",
                e,
            )
    amount_cents = int(round(overage_minutes * float(rate_cents)))
    amount_cents = max(MIN_OPTION_A_OVERAGE_CENTS, amount_cents)
    stripe_mod.InvoiceItem.create(
        customer=customer_id,
        amount=amount_cents,
        currency="usd",
        description=description,
        invoice=invoice_id,
    )


def _get_previous_month_period() -> tuple[str, str]:
    now = datetime.utcnow()
    if now.month == 1:
        y, m = now.year - 1, 12
    else:
        y, m = now.year, now.month - 1
    from calendar import monthrange
    last_day = monthrange(y, m)[1]
    start = f"{y:04d}-{m:02d}-01"
    end = f"{y:04d}-{m:02d}-{last_day:02d}"
    return start, end


def invoice_payg_for_previous_month(supabase, stripe_mod) -> dict[str, int]:
    period_start, period_end = _get_previous_month_period()
    r = supabase.table("users").select("id, stripe_customer_id").eq("billing_plan", "subscription_payg").not_.is_("stripe_customer_id", "null").execute()
    users = r.data or []
    invoiced = skipped = errors = 0

    for u in users:
        customer_id = u.get("stripe_customer_id")
        if not customer_id:
            continue
        existing = supabase.table("billing_invoices").select("stripe_invoice_id").eq("user_id", u["id"]).eq("period_start", period_start).eq("invoice_type", "payg").limit(1).execute()
        if existing.data and len(existing.data) > 0:
            skipped += 1
            continue

        usage = supabase.table("call_usage").select("payg_minutes, billed_minutes, duration_seconds").eq("user_id", u["id"]).gte("ended_at", f"{period_start}T00:00:00.000Z").lte("ended_at", f"{period_end}T23:59:59.999Z").execute()
        rows = usage.data or []
        total_minutes = sum(
            float(r.get("payg_minutes") or r.get("billed_minutes") or (r.get("duration_seconds") or 0) / 60)
            for r in rows
        )
        if total_minutes <= 0:
            skipped += 1
            continue

        subtotal = int(total_minutes * 20) + (1 if total_minutes * 20 % 1 else 0)
        amount_cents = max(MIN_INVOICE_CENTS, subtotal)
        try:
            inv = stripe_mod.Invoice.create(
                customer=customer_id,
                collection_method="charge_automatically",
                description=f"PAYG minutes {period_start} to {period_end}",
                metadata={"userId": u["id"], "period_start": period_start},
            )
            stripe_mod.InvoiceItem.create(
                customer=customer_id,
                amount=amount_cents,
                currency="usd",
                description=f"Pay As You Go ({total_minutes:.1f} min @ $0.20/min)",
                invoice=inv.id,
            )
            stripe_mod.Invoice.finalize_invoice(inv.id)
            supabase.table("billing_invoices").insert({
                "user_id": u["id"],
                "period_start": period_start,
                "invoice_type": "payg",
                "stripe_invoice_id": inv.id,
            }).execute()
            invoiced += 1
        except Exception as e:
            logger.error("[usageBilling] PAYG invoice failed: user=%s error=%s", u["id"], e)
            errors += 1
    return {"invoiced": invoiced, "skipped": skipped, "errors": errors}


def invoice_overage_for_fixed_plans(supabase, stripe_mod) -> dict[str, int]:
    period_start, period_end = _get_previous_month_period()
    r = supabase.table("user_plans").select("user_id, allocated_inbound_minutes, allocated_outbound_minutes, used_inbound_minutes, used_outbound_minutes, overage_rate_cents").not_.is_("allocated_inbound_minutes", "null").execute()
    plans = r.data or []
    invoiced = skipped = errors = 0

    for p in plans:
        alloc = (p.get("allocated_inbound_minutes") or 0) + (p.get("allocated_outbound_minutes") or 0)
        used = float(p.get("used_inbound_minutes") or 0) + float(p.get("used_outbound_minutes") or 0)
        overage = max(0, used - alloc)
        if overage <= 0:
            skipped += 1
            continue

        ur = supabase.table("users").select("stripe_customer_id").eq("id", p["user_id"]).limit(1).execute()
        customer_id = (ur.data[0].get("stripe_customer_id") if ur.data else None)
        if not customer_id:
            skipped += 1
            continue

        existing = supabase.table("billing_invoices").select("stripe_invoice_id").eq("user_id", p["user_id"]).eq("period_start", period_start).eq("invoice_type", "overage").limit(1).execute()
        if existing.data and len(existing.data) > 0:
            skipped += 1
            continue

        rate = p.get("overage_rate_cents") or DEFAULT_OVERAGE_RATE_CENTS
        subtotal = int(overage * rate) + (1 if (overage * rate) % 1 else 0)
        amount_cents = max(MIN_INVOICE_CENTS, subtotal)
        try:
            inv = stripe_mod.Invoice.create(
                customer=customer_id,
                collection_method="charge_automatically",
                description=f"Overage minutes {period_start} to {period_end}",
                metadata={"userId": p["user_id"], "period_start": period_start},
            )
            price_id = get_overage_price_id()
            if price_id:
                try:
                    qty = max(1, int(round(overage)))
                    stripe_mod.InvoiceItem.create(
                        customer=customer_id,
                        price=price_id,
                        quantity=qty,
                        description=f"Overage ({overage:.1f} min @ ${rate/100:.2f}/min)",
                        invoice=inv.id,
                    )
                except Exception as e:
                    logger.warning(
                        "[usageBilling] STRIPE_PRICE_OVERAGE failed (%s); amount fallback",
                        e,
                    )
                    stripe_mod.InvoiceItem.create(
                        customer=customer_id,
                        amount=amount_cents,
                        currency="usd",
                        description=f"Overage ({overage:.1f} min @ ${rate/100:.2f}/min)",
                        invoice=inv.id,
                    )
            else:
                stripe_mod.InvoiceItem.create(
                    customer=customer_id,
                    amount=amount_cents,
                    currency="usd",
                    description=f"Overage ({overage:.1f} min @ ${rate/100:.2f}/min)",
                    invoice=inv.id,
                )
            stripe_mod.Invoice.finalize_invoice(inv.id)
            supabase.table("billing_invoices").insert({
                "user_id": p["user_id"],
                "period_start": period_start,
                "invoice_type": "overage",
                "stripe_invoice_id": inv.id,
            }).execute()
            invoiced += 1
        except Exception as e:
            logger.error("[usageBilling] Overage invoice failed: user=%s error=%s", p["user_id"], e)
            errors += 1
    return {"invoiced": invoiced, "skipped": skipped, "errors": errors}


def option_a_invoice_closed_periods(supabase: Any, stripe_mod: Any) -> dict[str, int]:
    """
    Invoice Option A overage for usage_ledger periods that have ended (period_end < today)
    and have no subscription_invoices row yet. Base subscription fee is handled by Stripe.
    """
    today = date.today()
    r = supabase.table("usage_ledger").select("user_id, period_start, period_end").execute()
    periods: set[tuple[str, str, str]] = set()
    for row in r.data or []:
        pe = row["period_end"]
        if isinstance(pe, str):
            pe_d = date.fromisoformat(pe[:10])
        else:
            pe_d = pe
        if pe_d >= today:
            continue
        uid = str(row["user_id"])
        ps = row["period_start"]
        pe_s = row["period_end"]
        if isinstance(ps, str):
            ps = ps[:10]
        if isinstance(pe_s, str):
            pe_s = pe_s[:10]
        periods.add((uid, ps, pe_s))

    invoiced = skipped = errors = 0
    for user_id, ps, pe in periods:
        existing = (
            supabase.table("subscription_invoices")
            .select("id")
            .eq("user_id", user_id)
            .eq("period_start", ps)
            .eq("period_end", pe)
            .limit(1)
            .execute()
        )
        if existing.data and len(existing.data) > 0:
            skipped += 1
            continue

        ur = (
            supabase.table("users")
            .select("stripe_customer_id, billing_plan_metadata")
            .eq("id", user_id)
            .limit(1)
            .execute()
        )
        if not ur.data:
            skipped += 1
            continue
        customer_id = ur.data[0].get("stripe_customer_id")
        meta = ur.data[0].get("billing_plan_metadata") or {}
        if not customer_id:
            skipped += 1
            continue

        sr = (
            supabase.table("usage_ledger")
            .select("quantity")
            .eq("user_id", user_id)
            .eq("period_start", ps)
            .eq("period_end", pe)
            .execute()
        )
        total_min = sum(float(x.get("quantity") or 0) for x in (sr.data or []))
        included = int(meta.get("included_minutes") or 0)
        rate = int(meta.get("overage_rate_cents") or DEFAULT_OVERAGE_RATE_CENTS)
        overage_m = compute_overage_minutes(total_min, included)
        if overage_m <= 0:
            skipped += 1
            continue

        amount_cents = int(round(overage_m * float(rate)))
        if amount_cents <= 0:
            skipped += 1
            continue
        amount_cents = max(MIN_OPTION_A_OVERAGE_CENTS, amount_cents)

        try:
            inv = stripe_mod.Invoice.create(
                customer=customer_id,
                collection_method="charge_automatically",
                description=f"Voice overage {ps} to {pe}",
                metadata={
                    "userId": user_id,
                    "period_start": ps,
                    "period_end": pe,
                    "option_a": "true",
                },
            )
            _create_overage_invoice_item(
                stripe_mod,
                customer_id=customer_id,
                invoice_id=inv.id,
                overage_minutes=overage_m,
                rate_cents=rate,
                description=(
                    f"Voice minutes overage ({overage_m:.2f} min @ ${rate/100:.2f}/min)"
                ),
            )
            stripe_mod.Invoice.finalize_invoice(inv.id)
            sub_row = get_active_subscription(supabase, user_id)
            ins = supabase.table("subscription_invoices").insert(
                {
                    "user_id": user_id,
                    "subscription_id": (sub_row.get("id") if sub_row else None),
                    "period_start": ps,
                    "period_end": pe,
                    "subtotal_cents": amount_cents,
                    "total_cents": amount_cents,
                    "status": "open",
                    "provider_invoice_id": inv.id,
                }
            ).execute()
            iid = ins.data[0]["id"] if ins.data and len(ins.data) > 0 else None
            if iid:
                supabase.table("subscription_invoice_line_items").insert(
                    {
                        "invoice_id": iid,
                        "line_type": "overage",
                        "quantity": overage_m,
                        "unit_price_cents": rate,
                        "amount_cents": amount_cents,
                        "description": "Voice overage minutes",
                    }
                ).execute()
            invoiced += 1
        except Exception as e:
            logger.error("[usageBilling] Option A invoice failed user=%s: %s", user_id, e)
            errors += 1
    return {"invoiced": invoiced, "skipped": skipped, "errors": errors}
