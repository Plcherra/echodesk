# EchoDesk Launch Fix Plan

**Date:** July 29, 2026  
**Goal:** Fix all Critical and High priority issues from the UX audit, then launch.  
**Method:** One batch at a time → smoke test → next batch. Fresh agent per batch.

---

## Locked Decisions

| ID | Decision |
|----|----------|
| **C1** | Remove pure Free plan. Offer **14-day free trial for the first 100 customers** and show how many spots are left. |
| **C2** | Remove all Telnyx jargon from customer-facing UI. Use friendly language only. |
| **C3** | When a customer deletes a receptionist, show message: “Deletion requested. The number will be fully released in 24–48 hours.” (Manual release by us for now). |
| **C4** | WhatsApp and SMS = “Coming soon”. Hide any Telnyx/Meta setup CTAs. |
| **H1** | Remove unnecessary Account Settings items (Appointment confirmation, Payment link, Booking instructions). Keep real configuration only inside each Receptionist’s settings. |
| **H2** | App is **paid-only** after the first 100 trial customers. Route all Upgrade/Subscribe buttons directly to Checkout. |
| **H7** | Clean up Calendar / Integrations duplication. |

---

## Batch 1 — Critical Trust & Marketing (C1 + C4)

**Priority:** Highest  
**Status:** ✅ **Done / smoke-tested** (July 30, 2026)

### Tasks

1. **C1 – Pricing & Landing**
   - Remove any pure “Free” or “Start free” language.
   - Introduce: “14-day free trial for the first 100 customers”.
   - Show remaining trial spots (simple counter).
   - Make CTAs honest (“Start free trial” or “Create account”).

2. **C4 – WhatsApp / SMS**
   - Hide full WhatsApp/SMS setup.
   - Show only a clean “Coming soon” message + support email if needed.
   - Remove any “Open Telnyx / Meta” buttons.

### What shipped (Batch 1 + launch support)

- **Marketing landing** (`landing/`): 14-day trial card + spot counter (live via `GET /api/public/trial-offer`), paid tiers Starter $69/400 · Growth $129/850 · Business $179/1,350, overage **$0.20**/min; Enterprise removed.
- **Legal pages**: Privacy / Terms / Opt-in restyled to match landing; contact **echodesk2@gmail.com**.
- **Mobile Communication setup**: SMS/WhatsApp = Coming soon + support email; voice line shows **ready** when a number is assigned (no stuck “provisioning” copy).
- **Billing**: `stripe_plans.py` aligned to launch tiers; checkout allows Growth; VPS env uses new Stripe price IDs; overage billed by backend (amount fallback if metered price incompatible).
- **Auth email**: Confirm + reset templates branded EchoDesk; custom SMTP via **Resend** (`noreply@echodesk.us`); recovery email sending verified working.

### Smoke Test after Batch 1

- [x] Landing page pricing looks correct
- [x] No pure Free plan promised
- [x] Trial messaging + counter works
- [x] WhatsApp/SMS section only shows “Coming soon”
- [x] Communication setup voice line ready state (when number assigned)
- [x] Support email shows echodesk2@gmail.com (app) / legal pages
- [x] Password reset / confirm email send via Resend (not “supabase” sender once SMTP set)

---

## Batch 2 — Telnyx Customer Language (C2 + C3)

**Priority:** Critical  
**Status:** ⬜ Next

### Tasks

1. **C2 – Create Receptionist Phone Step**
   - Rewrite all copy to customer language (“We’ll set up a US business number…”).
   - Hide or remove “Telnyx Phone Number ID” field from normal flow (or put under Advanced).

2. **C3 – Delete Receptionist**
   - Change delete confirmation dialog.
   - After deletion, show: “Deletion requested. The number will be fully released in 24–48 hours.”
   - Send internal notification/email so we know to release the number manually.

### Smoke Test after Batch 2

- [ ] Create receptionist → phone step has no Telnyx jargon
- [ ] Delete receptionist → correct 24–48h message appears

---

## Batch 3 — Settings & Routing Cleanup (H1 + H2 + H7)

**Priority:** High

### Tasks

1. **H1** – Remove from Account Settings:
   - Appointment confirmation
   - Payment link defaults
   - Booking instructions
   - Keep real settings only inside each Receptionist.
   - Add Payment link configuration page inside of the assistant settings along services, promos, website and instructions.

2. **H2** – All “Upgrade first”, “Subscribe”, “Go to dashboard” (when unpaid) buttons must go directly to Checkout.

3. **H7** – Clean Calendar / Integrations section:
   - Remove duplicated options
   - Keep one clear Connect / Change Google Calendar path

### Smoke Test after Batch 3

- [ ] Account Settings no longer has the removed items
- [ ] Every Upgrade/Subscribe button goes to Checkout
- [ ] Calendar connection flow is clean

---

## Batch 4 — Copy, Errors & Empty States (H3 + H4 + H5 + H6)

**Priority:** High → Medium

### Tasks

1. **H3** – Replace all customer-visible `e.toString()` / Exception messages with friendly error text.
2. **H4** – Make “System prompt is required” customer-friendly (better label + default option + clearer error).
3. **H5** – Unify terminology: use **Receptionist** everywhere (remove “Assistant” where it confuses users).
4. **H6** – Improve empty states on Needs review / Upcoming / Completed so first-time users don’t feel lost.

### Smoke Test after Batch 4

- [ ] Trigger errors → only friendly messages appear
- [ ] Create receptionist → instructions step feels clear
- [ ] Empty states look intentional and helpful

---

## Batch 5 — Nice-to-have (After Launch)

- N1, N2, N3, N5, N6 – polish
- N4 – theme tokens (can wait)

---

## How we will work

1. Open a **fresh agent** for each batch.
2. Give the agent only the current batch section + relevant code context.
3. After the agent finishes, do the smoke test checklist.
4. Only move to the next batch when the current one passes.

---

**End of file.**
