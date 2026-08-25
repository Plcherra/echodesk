# EchoDesk Store Launch

Work one phase at a time. **Do not start the next phase until that phase’s test gate passes.** Do not submit to Play or the App Store until Phase 7.

## Decision summary

| Choice | Decision |
|--------|----------|
| Distribution | **Play Store + App Store only**, when the app is fully ready. No TestFlight / beta program as a launch gate |
| Customer surface at launch | **Mobile app**. Website is marketing + download + legal |
| Web app | **After launch** — same product in the browser later. Not in this plan |
| Voices | **Presets (Google) + optional clone (Pocket)** on the same Step 5 / settings screen |
| TTS default | Google Neural2 presets stay default. Do not claim we replaced Google |
| SMS / WhatsApp | Stay **Coming soon** |
| Unify presets onto Pocket | Deferred until ~10 paying customers + metering (Pocket plan Phase 6) |

### Launch rule

```text
Stranger hits echodesk.us
  → Get the app (Store)
  → Create account in the app
  → Calendar → receptionist (preset or optional clone) → number
  → Real inbound call works
Only then is EchoDesk launched.
```

---

## Current snapshot (2026-08-25)

**Live and working**

- Production API `https://echodesk.us/api/health`: Google configured, `pocket_tts` ok
- Stripe live (`sk_live`), Resend, Telnyx webhook on `echodesk.us`
- Trial offer: 14 days / 60 minutes / first 100 — **2 claimed, 98 left**
- Pocket sidecar `127.0.0.1:8100`, cloning weights loaded, concurrency 2
- App checkout: auth, onboarding, billing, receptionist wizard, calendar, calls
- Step 5 already has preset cards **and** `VoiceCloneSection` (“Use my voice”)
- Launch Batch 1 (pricing, SMS/WhatsApp coming soon) shipped

**Live test notes (2026-08-25, Carlo, production)**

- **Preset inbound call:** answered; booking hours bugs (10pm / lost “tomorrow”) were fixed in `d873fc28`. First-reply delay stays a later quality pass.
- **Clone create:** works after Pocket sidecar deploy (`aa1f7cfa` + copy/restart `pocket-tts`). Record 5–30s, preview, consent, Create clone.
- **Clone inbound call:** caller heard the cloned voice. Phone quality is low and there is extra latency — **fine-tune later**, do not block launch on it.
- **Clone booking:** the 1:16 AM call (`791e85b3…`, 111s, `outcome=booked`) **did write** an appointment. Spoken confirmation / slot list did not come back clearly on the phone (clone TTS lag). Result is in the app, not on the call:
  - **Appointments → Needs review** (generic bookings are under review, not Upcoming)
  - Wed Aug 26, **12:00–12:30 PM** EDT, summary “Appointment”
  - Earlier tonight (preset path) also booked **3:00–3:30 PM** EDT the same day — same Needs review tab
- **Still untested for Phase 2:** Pocket-down fallback (stop sidecar → backup Google voice + one notice), settings clone ↔ preset switch, file-upload clone.

**Gaps this plan closes**

1. A stranger cannot install or sign up (get-started still says run `./run_prod.sh`)
2. Live inbound call with a **preset** has been exercised; first-reply delay is deferred
3. Live inbound **clone** speech works; Pocket-down fallback and spoken booking confirmation still open
4. Landing does not mention optional clone
5. Store packaging (version, signing, listings, screenshots) is not done
6. Ops leftovers: leftover VPS tree; held-number cron exists but is never scheduled (deleted DIDs sit for weeks)

**Out of this plan**

- Building the web app
- Replacing Google presets with Pocket
- Turning on SMS / WhatsApp
- TestFlight-as-required-beta

---

## How to run this plan

1. Open one phase only.
2. Do the tasks.
3. Run **every** checkbox in that phase’s test gate on a **release build against production** (`API_BASE_URL=https://echodesk.us`).
4. Mark the Status table. Only then open the next phase.

Suggested agent prompt per phase:

```text
Execute only Phase N from .cursor/plans/store_launch/plan.md.
Do not start other phases. Do not submit to the stores.
After code changes, stop and wait for the test gate.
```

---

## Phase 1 — Prove the live product (preset path)

**Goal:** A release build can take a paying-or-trial customer from zero to a real answered call using a **Google preset**. If this fails, the app is not ready for stores.

### Tasks

- [ ] Install a **release** build on a real phone (sideload APK / local iOS run is OK here — stores come later)
- [ ] Confirm production dart-defines: `API_BASE_URL=https://echodesk.us` + live Supabase
- [ ] Walk the path below and fix any blocker you hit (copy, crash, 404, billing, onboarding)
- [ ] Confirm delete-receptionist copy: “Deletion requested. The number will be fully released in 24–48 hours.”
- [ ] Confirm an ops email or `[ops] MANUAL_PHONE_RELEASE_NEEDED` log when a number must be released

### Test gate — all must pass

- [ ] New email signup → confirm email → land back in the app
- [ ] Start **14-day trial** (or paid Starter if trial is skipped) → subscription/trial visible in Settings → Billing
- [ ] Connect Google Calendar
- [ ] Create receptionist: skip clone, pick a preset, get a US business number
- [ ] Call that number from another phone → greeting plays, booking or a sensible answer works
- [ ] Call appears in history / minutes increment
- [ ] Delete receptionist shows the 24–48h number-release message
- [ ] No Telnyx jargon in the create-phone step
- [ ] SMS / WhatsApp still say Coming soon

**Exit:** Preset path is demo-safe. Clone is not required to pass this phase.

---

## Phase 2 — Prove clone beside presets

**Goal:** Optional “Use my voice” works on the same Step 5 / settings screen as presets. Clone calls speak; if Pocket dies, the caller still hears a stock Google voice plus one short notice.

Already built. This phase is **test + fix**, not a new wizard step.

### Tasks

- [ ] On the same release build, create or edit a receptionist and use **Use my voice**
- [ ] Record ~5–20s quiet speech **and** try file upload
- [ ] Consent required (reject without it)
- [ ] Preview plays before save
- [ ] Selecting a preset clears the clone; selecting a clone keeps last preset as fallback metadata
- [ ] Live inbound call uses Pocket (check `[TTS_METER]` / logs: `provider=pocket`)
- [ ] Stop `pocket-tts`, call again: spoken notice once, then Google preset — never silence
- [ ] Start `pocket-tts` again; health returns `pocket_tts: ok`

### Test gate — all must pass

- [ ] New user can finish onboarding **without** cloning (Phase 1 still holds)
- [ ] Step 5 shows presets **and** Use my voice
- [ ] Clone → preview → bind → inbound call sounds like the sample (phone quality OK)
- [ ] Settings can switch clone ↔ preset without recreating the receptionist
- [ ] Pocket down → backup voice + notice, call continues
- [ ] Logs distinguish Google vs Pocket (chars, ms, `fallback_used`)

**Exit:** Voices are launch-ready. Do not add a separate “clone onboarding” step.

---

## Phase 3 — Website copy (app-only, no web signup)

**Goal:** echodesk.us matches the product you are about to put on the stores. No repo commands. No web app. Mention optional clone.

### Tasks

- [ ] Landing: keep five professional voices; add **optional: use your own voice**
- [ ] Do **not** say we replaced Google TTS or that there is one unified engine
- [ ] Rewrite `/get-started`:
  - Remove `./run_prod.sh` / “no web signup yet” / Mac-from-repo steps
  - Copy: create the account **in the EchoDesk app**
  - Buttons: App Store + Play (placeholder URLs until Phase 7) + “Open app” deep link + support email
- [ ] Short support note (Help screen and/or get-started): quiet room, 5–20s, no music; if clone drops to a stock voice, that is expected during a VPS issue
- [ ] Deploy landing (`DEPLOY_LANDING=1` / `deploy-landing.sh`)

### Test gate

- [ ] echodesk.us homepage mentions optional clone without overclaiming
- [ ] `/get-started?plan=trial` (and starter/growth/business) has **no** git/run_prod instructions
- [ ] Primary CTAs are store download (or “listing soon” + email) — not a web signup form
- [ ] Privacy / Terms / Opt-in still reachable
- [ ] Support email is `echodesk2@gmail.com`

**Exit:** A stranger understands: download the app, optional clone exists, no browser product yet.

---

## Phase 4 — Store packaging

**Goal:** One signed iOS build and one signed Android App Bundle ready to upload. Do not press Submit yet.

### Tasks

**Shared**

- [ ] Bump `mobile/pubspec.yaml` version (not `1.0.0+1`)
- [ ] Production dart-defines baked in
- [ ] Screenshots + short description + full description (voices: presets + optional clone)
- [ ] Privacy nutrition / data-safety forms match what the app actually does (account, calendar, mic for optional clone, call recordings, payments)

**Android (`com.echodesk.mobile`)**

- [ ] Create and lock a Play upload keystore (`key.store` in `local.properties` — never commit secrets)
- [ ] `flutter build appbundle --release` with production defines
- [ ] Play Console listing draft (store graphic, category, content rating)

**iOS (`com.echodesk.echodeskMobile`)**

- [ ] Apple Developer + App Store Connect app record
- [ ] Signing / bundle ID match
- [ ] `flutter build ipa --release` with production defines
- [ ] Listing draft (screenshots, privacy policy URL `https://echodesk.us/privacy`)

### Test gate

- [ ] Release IPA installs on a device and hits production (Phase 1 + 2 smoke, shortened: signup + one preset call)
- [ ] Release AAB / signed APK same smoke on Android
- [ ] Mic permission copy is honest (clone only)
- [ ] Checkout return (`echodesk://checkout`) and email confirm return to the app
- [ ] No debug/dev plan names in Settings billing

**Exit:** Binaries and listings are ready. **Do not submit.**

---

## Phase 5 — Ops watch (same week as submit)

**Goal:** You can run the shop for the first 100 trial customers without losing the VPS tree or missing transfer requests. Number release itself is Phase 6 — do not treat email-watching as the release process.

### Tasks

- [ ] On the VPS: `sudo rm -rf /opt/echodesk/app.pre-reset-` (root-owned leftover from the Aug 20 reset)
- [ ] Confirm `echodesk-backend` and `pocket-tts` enabled + active
- [ ] Watch `SUPPORT_EMAIL` (`echodesk2@gmail.com`) for number-transfer “Under review” requests
- [ ] Know the one-liner: if clone calls go stock, check `systemctl status pocket-tts` and `/api/health` `pocket_tts`
- [ ] Confirm trial counter on the landing updates from `/api/public/trial-offer`

### Test gate

- [ ] Leftover `app.pre-reset-` is gone
- [ ] `https://echodesk.us/api/health` still `pocket_tts: ok`
- [ ] Transfer request still emails ops (if you offer transfer at launch)

**Exit:** Day-to-day ops is boring. Held-number automation is the next phase, not email-watching.

---

## Phase 6 — Automate held-number release

**Goal:** Unused held DIDs actually leave Telnyx and the app after 48 hours, on a schedule, without anyone watching email. The release code already exists (`GET /api/cron/release-held-numbers`, Bearer `CRON_SECRET`). Nothing on the VPS calls it today — that is why +1 617-499-9456 and +1 310-584-7719 are still “release pending” from Aug 12.

Do this **before** store submit. A paying customer who deletes a receptionist must not keep a ghost number (or be blocked from a new one) for weeks.

### Tasks

- [ ] Add a systemd timer (preferred, matches `echodesk-backend`) **or** a root crontab that hits localhost hourly:
  `curl -fsS -H "Authorization: Bearer $CRON_SECRET" http://127.0.0.1:8000/api/cron/release-held-numbers`
- [ ] Install, enable, and start the timer on the VPS (`deploy/systemd/` + a one-line note in `docs/ops/RUNBOOK.md`)
- [ ] One-shot the same endpoint now so the two Aug 12 leftovers release (Telnyx delete + DB detach + customer email)
- [ ] Confirm the app no longer shows those two as held (pull-to-refresh Receptionists)
- [ ] Keep `POST /api/internal/phone-numbers/release` as the manual fallback if Telnyx delete fails (cron already logs `[cron/release-held] Telnyx release failed` and skips the DB clear)
- [ ] Optional same unit: other `/api/cron/*` jobs (usage, usage-alerts) if they are also unscheduled — only if cheap; do not block this phase on billing cron

### Test gate — all must pass

- [ ] `systemctl status` (or `crontab -l`) shows the hourly job enabled
- [ ] Journal / logs show a successful `[cron/release-held]` run (`ok: true`)
- [ ] The two stale holds (`+16174999456`, `+13105847719`) are gone from Telnyx **and** from the app
- [ ] A fresh delete still shows the 24–48h copy; after the next hourly run **past** 48h, the number is gone (or prove with a one-shot after 48h on a test delete)
- [ ] Manual fallback still documented: `POST /api/internal/phone-numbers/release`

**Exit:** 48-hour release is a machine job. Manual release is fallback only. Then open Phase 7.

---

## Phase 7 — Submit stores and run the stranger path

**Goal:** Listings go live. A person who does not have the repo can become a customer.

### Tasks

- [ ] Paste real App Store + Play URLs into `/get-started` and landing CTAs; redeploy landing
- [ ] Submit iOS + Android
- [ ] Answer review questions (mic = optional voice clone; calendar = booking; recordings = call history)
- [ ] After **Approved / Published**, run the stranger path below on a phone that never had a sideload

### Test gate — launch is done only when these pass

- [ ] Phone with no repo: store install → Create account → trial or paid → calendar → receptionist (preset) → inbound call
- [ ] Same phone: optional clone in Step 5 → inbound call
- [ ] `/get-started` store buttons open the real listings
- [ ] Trial spots decrement after a new trial claim
- [ ] Support email reaches you

**Exit:** EchoDesk is launched. Web app is a later project, not a hotfix.

---

## Acceptance criteria (all phases)

1. New user completes onboarding **without** cloning.
2. Step 5: pick a Google preset (default) **or** optionally clone.
3. Test call with preset = Google path.
4. Test call with clone = Pocket path.
5. Pocket down = Google stock + one spoken notice, never silent.
6. Stranger installs from a store, not from git.
7. Website does not promise a web app or a Google-TTS replacement.
8. Unused held numbers auto-release after 48 hours (hourly cron). Manual `POST /api/internal/phone-numbers/release` is fallback only.

---

## Suggested build order

```text
Phase 1 preset call  →  Phase 2 clone call  →  Phase 3 website copy
     →  Phase 4 store packages  →  Phase 5 ops
     →  Phase 6 held-number cron  →  Phase 7 submit
Web app: after launch, separate plan
```

---

## Status

| Phase | Status |
|-------|--------|
| 1 Prove preset path | In progress (live call done; first-reply delay deferred) |
| 2 Prove clone path | In progress (clone create + inbound speech passed; quality/latency later; Pocket-down + spoken booking confirmation still open) |
| 3 Website copy | Not started |
| 4 Store packaging | Not started |
| 5 Ops watch | Not started |
| 6 Held-number cron | Not started (endpoint exists; no VPS schedule) |
| 7 Submit stores | Blocked on 1–6 |
| Web app | After launch — out of scope |

### Related

- Pocket hybrid (already built): `.cursor/plans/pocket_tts_hybrid_clone/plan.md`
- Older UX launch batches: `docs/ECHODESK_LAUNCH_FIX_PLAN.md` (Batch 1 done; leftover smoke lives in Phase 1)
- Get-started (must change in Phase 3): `landing/src/pages/get-started.astro`
- Voice UI: `mobile/lib/screens/receptionists/create_receptionist_screen.dart` Step 5 + `mobile/lib/widgets/voice_clone_section.dart`
