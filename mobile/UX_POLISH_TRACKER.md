# EchoDesk mobile UX polish tracker

Last updated: 2026-07-29  
Source: mobile UX audit + polish passes on `main`.

## Summary

| Priority | Meaning | Status |
|----------|---------|--------|
| **P0** | Demo-blocking / embarrassing | **Done** — do not touch |
| **P1** | Dashboard Overview cleanup | **Done** (+ hierarchy refinement) |
| **P2** | Remaining polish (former leftover P1) | **Done** (after #14) |
| **P3** | Receptionist Area Redesign | **Done** |
| **P4** | Nice-to-have (former P3) | **Done** |

**How many P levels?** Five: **P0**, **P1**, **P2**, **P3**, **P4**.

**Is P0 finished?** Yes. Rebuild and run [P0 smoke tests](#p0-manual-smoke-tests) anytime.

**Is P1 finished?** Yes (includes 2026-07-28 hierarchy refinement). Rebuild and run [P1 smoke tests](#p1-manual-smoke-tests).

**Is P2 finished?** Yes. Rebuild and run [P2 manual smoke tests](#p2-manual-smoke-tests-historical--already-shipped-items).

**Is P3 finished?** Yes (2026-07-28). Rebuild and run [P3 manual smoke tests](#p3-manual-smoke-tests).

**Is P4 finished?** Yes (2026-07-29). Rebuild and run [P4 manual smoke tests](#p4-manual-smoke-tests).

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
| 7 | Stronger numbers, quieter labels, consistent padding | Done | EchoDesk theme tokens |
| 8 | Tighten Recent Calls so it doesn’t compete | Done | `titleSmall`, denser tiles, show 3, hide dead chevrons |

### P1 refinement (2026-07-28) — denser hierarchy

Follow-up polish on the same Overview section (still P1). Problem: two large equal-weight cards after Minutes left awkward empty space and weak hierarchy.

| # | Item | Status | Notes |
|---|------|--------|-------|
| R1 | Hero Minutes this period | Done | Larger number (`headlineMedium`), remaining in green, thin usage progress bar |
| R2 | Compact status row | Done | Replaces Active + Calendar cards: `Active N · Calendar Connected · phone` (phone only if set) |
| R3 | Lifetime caption quieter | Done | Smaller soft caption under status row |
| R4 | Tighter vertical spacing | Done | Less gap after hero; denser Overview → Recent Calls |

### P1 manual smoke tests

1. **Appointments card unchanged**
   - Top card still shows Appointments + needs-review badge when count > 0.
   - Tap still opens Appointments (needs_review deep link when badge present).

2. **Overview hierarchy**
   - Minutes this period is the clear hero (largest number + progress bar).
   - Active receptionists, Calendar, and optional phone sit in one compact status strip (no large secondary cards).
   - Default phone appears only if a number is set; “Not set” is not shown.
   - Lifetime “N calls · X.X min lifetime” is a quiet caption under the status row.
   - No separate Total Calls / Total Minutes / Total Receptionists cards.

3. **Recent Calls quieter**
   - Section title is smaller than Overview.
   - At most 3 recent calls shown.
   - Rows are denser; chevron only when the row is tappable.

---

## P2 — Remaining polish (former leftover P1) — DONE

Started 2026-07-28. Finished 2026-07-28 (incl. onboarding Ready step).

| # | Item | Status | Suggested smoke when done |
|---|------|--------|---------------------------|
| 9 | Today tab multi-assistant dead-end — no picker/CTA | Done | Multi-assistant Today shows list + Manage assistants |
| 10 | Call detail without `extra` — “Call not found”, no fetch-by-id | Done | Cold open fetches by id; friendly retry/error |
| 11 | Dashboard call rows look tappable when `receptionist_id` missing | Done* | *Addressed as part of P1 Recent Calls tighten (no chevron when not navigable) |
| 13 | Optional confirm dialog before Confirm appointment | Done | needs_review Confirm → “Confirm this appointment?” dialog |
| 14 | Onboarding step 4 distinct “You’re ready” (not reuse test-call UI) | Done | Step 4 = Ready card; Test call stays on step 3 only |
| 17 | Shared loading pattern (skeletons vs spinner) | Done | List screens use shared `ListLoadingView` skeletons |
| 18 | Ad-hoc Colors vs `EchoDeskColors` | Done | Status chips, list accents, empty/error, call screens |
| 19 | Settings billing/calendar: remove full-screen dim overlay | Done | Only row spinner while loading |
| 20 | Create receptionist padding 16 → 24 | Done | Matches other tabs |
| 21 | Help screen: `constrainedScaffoldBody` + padding 24 | Done | Layout matches Settings |
| 22 | Help support email branded / configurable | Done | `Env.supportEmail` → `support@echodesk.us` (SUPPORT_EMAIL override) |
| 23 | Delete receptionist success SnackBar | Done | “deleted” SnackBar before navigate away |
| 24 | Active call: confirm End; clarify back vs hang up | Done | End confirms; back offers Stay / Leave screen / End call |

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

## P3 — Receptionist Area Redesign (DONE)

Goal: Make the Receptionist experience feel modern, calm, and consistent with the improved Dashboard. Remove the heavy full-width button stack.

Finished 2026-07-28.

| # | Item | Status | Notes |
|---|------|--------|-------|
| R1 | Receptionist Detail page redesign | Done | Compact info chips + 2×2 actions + Dashboard-style Recent Calls |
| R2 | Receptionists list: consistent card style and spacing | Done | Dense cards, status badge, EchoDesk tokens |
| R3 | Receptionist Settings: cleaner grouping | Done | Calendar card; Instructions sections; 24px padding |
| R4 | Add Service modal: better spacing / Duration+Price side-by-side / Follow-up | Done | Basics + Location + Follow-up visual groups |

### P3 manual smoke tests

1. **Receptionist Detail**
   - Header shows name, active badge, phone.
   - Info is compact (chips / tight key-value) — no heavy Overview card.
   - Primary actions are a compact grid (not full-width stacked buttons): Call back, Appointments, Copy number, Settings / View Calls.
   - Recent calls match Dashboard density (`titleSmall`, dense rows, max 3).
   - Navigation and delete still work.

2. **Receptionists list** (when R2 done)
   - Cards/spacing feel consistent with Detail and Dashboard.

3. **Settings + Add Service** (when R3–R4 done)
   - Settings sections are clearly grouped.
   - Add Service: Duration + Price side-by-side; Follow-up visually grouped.

---

## P4 — Nice-to-have (former P3) — DONE

Started 2026-07-29. Finished 2026-07-29.

| # | Item | Status | Notes |
|---|------|--------|-------|
| 25 | Brand casing: “Echodesk” → “EchoDesk” in welcome copy | Done | Welcome, reset password, MaterialApp title, push/call appName, iOS/Android labels |
| 26 | Generic badge min text size / TextScaler | Done | StatusChip, OutcomeChip, GenericBadge, list badges clamp 11–16 |
| 27 | Semantics / text-scale spot-check on icon buttons | Done | Tooltips on Dashboard/Onboarding/Settings/Receptionists icon actions |
| 28 | `.SF Pro Text` on Android — platform/bundled font | Done | SF Pro on Apple; Roboto elsewhere |
| 29 | Shared `_OutcomeChip` (call history + receptionist detail) | Done | `widgets/outcome_chip.dart` |
| 30 | Appointment transcript expand / “View full” | Done | Expand/collapse past 500 chars |
| 31 | Onboarding error state matches shared ErrorStateView | Done | Same Retry layout as other screens |
| 32 | Checkout `Navigator.pop` → `context.pop()` | Done | go_router |
| 33 | Receptionist long-press-to-call discoverability | Done | Phone icon + list hint; long-press kept |
| 34 | Settings calendar subtitle shows Google email, not raw calendar id | Done | Email-shaped id or account email; booking label friendly |
| 35 | Push deep-link for new appointment → Needs review | Done | Backend FCM + mobile `onNavigate` → `/appointments?status=needs_review` |
| — | Delete success SnackBars (services / locations / promos) | Done | Matches receptionist delete feedback |

### P4 manual smoke tests

1. **Brand casing** — Dashboard welcome + home-screen app label read **EchoDesk** (not Echodesk).
2. **Checkout Back** — Failed checkout → Back uses go_router pop (no stack glitch).
3. **Onboarding error** — Force setup load failure → shared ErrorStateView + Retry.
4. **Delete feedback** — Delete a service / location / promo → success SnackBar before list reloads.
5. **Outcome chip** — Call history / receptionist detail / call detail use the same chip colors.
6. **Transcript** — Long appointment transcript shows **View full** / **Show less**.
7. **Calendar subtitle** — Settings Google Calendar shows “Connected as you@gmail.com” (not opaque id).
8. **Outbound call** — Receptionists list shows phone icon + hint; tap/long-press opens call sheet.
9. **Badge text scale** — Large accessibility text still keeps chips readable (min ~11).
10. **Icon tooltips** — Long-press Help / Settings / Sign out shows tooltip.
11. **Android font** — Body text uses Roboto (not missing SF Pro glyphs).
12. **Appointment push** — New needs_review booking notification opens Appointments → Needs review.

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
- **In progress** — actively being worked
- **P0** — demo blockers (locked)
- **P1** — Dashboard Overview cleanup (done)
- **P2** — remaining polish (done)
- **P3** — Receptionist Area Redesign (done)
- **P4** — nice-to-have (done)
