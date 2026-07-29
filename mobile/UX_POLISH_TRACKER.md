# EchoDesk mobile UX polish tracker

Last updated: 2026-07-28  
Source: mobile UX audit + polish passes on `main`.

## Summary

| Priority | Meaning | Status |
|----------|---------|--------|
| **P0** | Demo-blocking / embarrassing | **Done** — do not touch |
| **P1** | Dashboard Overview cleanup | **Done** |
| **P2** | Remaining polish (former leftover P1) | Todo |
| **P3** | Nice-to-have (former P2) | Todo |

**How many P levels?** Four: **P0**, **P1**, **P2**, **P3**.

**Is P0 finished?** Yes. Rebuild and run [P0 smoke tests](#p0-manual-smoke-tests) anytime.

**Is P1 finished?** Yes. Rebuild and run [P1 smoke tests](#p1-manual-smoke-tests).

### Rebuild (Mac)

```bash
cd ~/Desktop/echodesk && git pull origin main && cd mobile && ./run_prod.sh 00008150-000C03C83A2B401C release
```

---

## P0 — Demo-blocking (DONE — do not touch)

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Dashboard refreshes on tab focus + after returning from child routes | Done | Quiet refresh; no full-screen skeleton flash |
| 2 | Dashboard surfaces appointment load failures (not fake empty) | Done | Non-blocking error card + Retry |
| 3 | Confirm before sign-out (Dashboard) | Done | Shared `confirmSignOut` dialog |
| 4 | Confirm before sign-out (Settings + Onboarding) | Done | Same dialog |
| 5 | Settings plan copy matches what customers can buy | Done | Subtitle: **Starter, Business**; Pro removed; Dev hidden |

### Earlier polish already shipped with P0 (kept for history)

| # | Item | Status |
|---|------|--------|
| A | Confirm / edit failures show SnackBars with API error | Done |
| B | Terminology: Reject → **Cancel** / **Cancelled** (no Declined) | Done |
| C | Shared empty / error states (Dashboard, Appointments, Receptionists) | Done |
| D | Needs-review tab badge refreshes on pull-to-refresh + tab focus | Done |
| E | Appointment detail: sticky Confirm/Cancel + **More actions** sheet | Done |

### P0 manual smoke tests

Do these after a release rebuild. Mark each ✅ / ❌.

1. **Fresh booking appears without pull-to-refresh**
   - Open Dashboard.
   - Switch away to Appointments (or Settings), then back to Dashboard — list/counts should reload.
   - From Dashboard, open an appointment → Confirm or Cancel → pop back — Dashboard should reflect the change without pull-to-refresh.
   - Optional: place a real call that books → return to Dashboard tab → new booking / needs-review count should show up without pull-to-refresh.

2. **Appointment load failure is visible**
   - Hard to force without breaking the API; if appointments fail, expect a red “Could not load appointments” card with Retry (not a silent “No upcoming appointments”).
   - Happy path: with network OK, upcoming list or empty state loads normally (no error card).

3. **Sign-out confirmation**
   - Dashboard app bar logout → dialog “Sign out?” → **Stay signed in** keeps you in.
   - Repeat → **Sign out** actually signs out.
   - Settings → Sign Out → same dialog.
   - Onboarding (if you can reach it) → logout icon → same dialog.

4. **Plan copy / checkout alignment**
   - Settings → Billing → Subscribe / Upgrade subtitle reads **Starter, Business** (no Pro, no DEV test).
   - Open checkout plan picker → only **Starter** and **Business** cards.
   - Dashboard / Receptionists upgrade copy says **Subscribe to continue** (not “Upgrade to Pro”).

---

## P1 — Dashboard Overview cleanup (DONE)

Goal: calmer Overview without changing overall information architecture. Appointments card unchanged.

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Keep top “Appointments – X need review” card as-is | Done | Untouched |
| 2 | Prioritize Minutes this period (with remaining/overage) | Done | Full-width primary metric card |
| 3 | Prioritize Active receptionists + Calendar | Done | Side-by-side secondary cards |
| 4 | Default phone only when set (hide “Not set”) | Done | Quiet full-width row when present |
| 5 | Demote Total Calls + Total Minutes | Done | Quiet lifetime footer line (not peer cards) |
| 6 | Remove noisy Total Receptionists peer card | Done | Active count is enough in Overview |
| 7 | Stronger numbers, quieter labels, consistent padding | Done | `_OverviewMetricCard` + EchoDesk theme tokens |
| 8 | Tighten Recent Calls so it doesn’t compete | Done | `titleSmall`, denser tiles, show 3, hide dead chevrons |

### P1 manual smoke tests

1. **Appointments card unchanged**
   - Top card still shows Appointments + needs-review badge when count > 0.
   - Tap still opens Appointments (needs_review deep link when badge present).

2. **Overview hierarchy**
   - Minutes this period is the largest / first Overview metric.
   - Active receptionists and Calendar sit side-by-side below it.
   - Default phone appears only if a number is set; “Not set” is not shown as a card.
   - Lifetime “N calls · X.X min lifetime” is a quiet line under Overview (not equal-weight cards).
   - No separate Total Calls / Total Minutes / Total Receptionists cards.

3. **Recent Calls quieter**
   - Section title is smaller than Overview.
   - At most 3 recent calls shown.
   - Rows are denser; chevron only when the row is tappable.

---

## P2 — Remaining polish (former leftover P1) — TODO

Do not start until explicitly asked.

| # | Item | Status | Suggested smoke when done |
|---|------|--------|---------------------------|
| 9 | Today tab multi-assistant dead-end — no picker/CTA | Todo | With 2+ receptionists, Today shows a clear path to pick one |
| 10 | Call detail without `extra` — “Call not found”, no fetch-by-id | Todo | Open call via deep link / cold path → loads or friendly retry |
| 11 | Dashboard call rows look tappable when `receptionist_id` missing | Done* | *Addressed as part of P1 Recent Calls tighten (no chevron when not navigable) |
| 13 | Optional confirm dialog before Confirm appointment | Todo | Confirm needs_review → dialog or undo snackbar |
| 14 | Onboarding step 4 distinct “You’re ready” (not reuse test-call UI) | Todo | Finish setup shows a clear Done state |
| 17 | Shared loading pattern (skeletons vs spinner) | Todo | Lists feel consistent while loading |
| 18 | Ad-hoc Colors vs `EchoDeskColors` | Todo | Status/warning colors match theme (Overview already uses tokens) |
| 19 | Settings billing/calendar: remove full-screen dim overlay | Todo | Only row spinner while loading |
| 20 | Create receptionist padding 16 → 24 | Todo | Matches other tabs |
| 21 | Help screen: `constrainedScaffoldBody` + padding 24 | Todo | Layout matches Settings |
| 22 | Help support email branded / configurable | Todo | No `echodesk2@gmail.com` in demo |
| 23 | Delete receptionist success SnackBar | Todo | Brief “deleted” before navigate away |
| 24 | Active call: confirm End; clarify back vs hang up | Todo | End asks confirm; back doesn’t silently strand |

### P2 manual smoke tests (historical — already shipped items)

1. **Confirm / Cancel feedback**
   - Open a needs_review appointment → **Confirm** → success snackbar + status Confirmed.
   - Open another → **Cancel** → confirmation dialog → Cancel appointment → status **Cancelled**.
   - If you can force an API failure (airplane mode mid-save), expect a failure SnackBar.

2. **More actions**
   - Sticky bar shows Confirm / Cancel (when applicable).
   - **More actions** opens sheet with edit service/notes, payment link, send/resend confirmation, etc.

3. **Needs-review badge**
   - Appointments tab → note badge count.
   - Pull to refresh on Today or Upcoming → badge updates if count changed.
   - Leave Appointments tab, return → badge refreshes.

4. **Empty / error UX**
   - Appointments empty tabs show icon + title (not bare text).
   - Receptionists error path (if forced) shows Retry layout, not raw `Error: …`.

---

## P3 — Nice-to-have (former P2) — TODO

Do not start until explicitly asked.

| # | Item | Status |
|---|------|--------|
| 25 | Brand casing: “Echodesk” → “EchoDesk” in welcome copy | Todo |
| 26 | Generic badge min text size / TextScaler | Todo |
| 27 | Semantics / text-scale spot-check on icon buttons | Todo |
| 28 | `.SF Pro Text` on Android — platform/bundled font | Todo |
| 29 | Shared `_OutcomeChip` (call history + receptionist detail) | Todo |
| 30 | Appointment transcript expand / “View full” | Todo |
| 31 | Onboarding error state matches shared ErrorStateView | Todo |
| 32 | Checkout `Navigator.pop` → `context.pop()` | Todo |
| 33 | Receptionist long-press-to-call discoverability | Todo |
| 34 | Settings calendar subtitle shows Google email, not raw calendar id | Todo |
| 35 | Push deep-link for new appointment → Needs review | Todo |

### P3 manual smoke tests

Skip until items are implemented. Then add one check per shipped row above.

---

## Deferred (explicitly out of current polish)

| Item | Notes |
|------|--------|
| Dashboard “Needs attention” full visual restructure | Broader than Overview cleanup |
| Free trial for first ~50–100 early customers | Mechanism TBD (coupon / signup flag) |

## Separate launch tracks (not UX P-levels)

| Track | Status |
|-------|--------|
| Launch readiness review (security, secrets, monitoring, legal) | Pending |
| GitHub publish package + polished README | Pending |

---

## Quick legend

- **Done** — shipped on `main`
- **Todo** — still open
- **P0** — demo blockers (locked)
- **P1** — Dashboard Overview cleanup (done)
- **P2** — remaining noticeable polish
- **P3** — nice-to-have
