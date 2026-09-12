# Agent handoff — EchoDesk store launch (4 Sep 2026 ~22:45 ET)

Paste this whole file (or the Prompt section) into a **new agent**. Owner is busy 5–10 minutes and **cannot smoke-test**. Do not wait for them. Do not submit to the stores.

---

## Prompt

You are continuing EchoDesk store-launch work in `c:\Users\admin\Documents\cursor\echodesk\echodesk`.

**Source of truth:** `.cursor/plans/store_launch/plan.md`  
**Phone checklist (owner taps later):** `.cursor/plans/store_launch/manual_prelaunch_tests.md`

### Locked decisions — do not reopen

- Launch = Play Store + App Store when the **app** is fully ready. No TestFlight gate.
- Customer surface at launch = **mobile app only**. Web app is after launch. No web signup form.
- Voices at launch = **Google presets only**. Pocket / “Use my voice” is **paused** (`VOICE_CLONE_ENABLED=false`). Do not spend time on clone quality, latency, or fallback.
- SMS / WhatsApp stay **Coming soon**.
- Do **not** claim we replaced Google TTS.
- Phone numbers: **detach from the customer, keep on our Telnyx account**, reuse on the next receptionist. Do **not** Telnyx-delete on account delete or on the 48h hold job. Manual Telnyx delete is only `POST /api/internal/phone-numbers/release`.

### Production snapshot

- API `https://echodesk.us/api/health` — Google + Pocket sidecar ok (Pocket unused for live calls while clone is paused).
- Stripe live. Trial: 14 days / 60 min / first 100. About 98 spots left last check.
- VPS: `/opt/echodesk/app` as user `echodesk`. SSH alias `echodesk`. `sudo` needs a password except `systemctl restart|start|stop echodesk-backend`.
- Leftover tree still on box: `/opt/echodesk/app.pre-reset-` (needs sudo to delete — skip if you cannot).
- Telnyx now has **two** DIDs:
  - `+1 617-613-7764` — Eve, original May production line (keep).
  - `+1 310-584-7719` — re-bought tonight for receptionist Ash after Delete account **Telnyx-deleted** the old holds. `+1 617-499-9456` is gone from Telnyx.
- Confirm emails: Supabase Auth + Resend `noreply@echodesk.us`. Logo-in-email HTML is in repo but **not** pasted into the hosted Auth template yet (needs Dashboard).

### Git

- Branch: `main`, tracking `origin/main`.
- HEAD last seen: `2d1e1d8c` (PasswordField on auth screens). Password show/hide + strength rules are **already committed**.
- **Uncommitted (commit these first if they still look correct):**
  - `backend/api/mobile/account.py` — delete account **detaches** DIDs, does not Telnyx-delete
  - `backend/cron/release_held_numbers.py` — 48h job detaches only
  - `backend/telnyx/phone_lifecycle.py` — detach uses `phone_number=""` (column is NOT NULL)
  - `backend/tests/test_mobile_account_delete.py`
  - `.cursor/plans/store_launch/plan.md` — Phase 6 wording: keep DID on Telnyx
  - untracked: `supabase/email-templates/` and `landing/public/images/echodesk-email-mark.png` (+ dist copy)
- **Do not commit** `.env`, tokens, `supabase/.temp/*`.
- **Commit and push** when the detach change is clean (owner previously wanted launch work shipped). Then deploy so VPS matches: GitHub Action on `main` does `git reset --hard origin/main` + `deploy-systemd.sh`. If CI is blocked by dirty VPS files, do **not** `git pull` over dirt; reset like last time, never delete `.env`.

### What to do now (no owner, no device)

Work **Phase 3**, then as much of **Phase 5/6 packaging** as you can without store credentials. Skip Phase 1/7 smoke (owner will tap the phone later). Skip Phase 2 clone.

**1. Commit + push + get the detach fix onto the VPS**

- Review the uncommitted phone-lifecycle change. Run `pytest backend/tests/test_mobile_account_delete.py backend/tests/test_phone_lifecycle.py`.
- Commit with a why-message (detach, don’t Telnyx-delete). Push `main`.
- Confirm production backend restarted on the new commit (`git -C /opt/echodesk/app log -1`).

**2. Phase 3 — website copy (required for launch)**

- Rewrite `landing/src/pages/get-started.astro`: **no** `./run_prod.sh`, no “clone the repo”, no Mac-from-repo steps.
- Copy: create the account **in the EchoDesk app**. Buttons: App Store + Play as **placeholders** (“Listing soon”) + `echodesk://auth-callback` + `echodesk2@gmail.com`.
- Landing (`landing/src/pages/index.astro`): five professional voices only. **Do not mention clone / use your own voice.**
- Deploy landing if you can (`DEPLOY_LANDING=1` / `bash deploy/scripts/deploy-landing.sh`). `/var/www/echodesk-landing` is `www-data`; passwordless sudo may fail — then leave files ready and note that landing deploy needs the owner’s sudo.
- Also add `echodesk-email-mark.png` to the live landing `images/` if you can write there (same sudo issue). Confirm template still works with `https://echodesk.us/images/echodesk-logo-mark.png` if the small file is not live.

**3. Auth confirm email (Dashboard, if you have access)**

- HTML is `supabase/email-templates/confirmation.html`.
- Paste into Supabase project `jytqdlhnvbmjdsgziqpx` → Authentication → Email Templates → Confirm signup.
- Subject: `Confirm your EchoDesk account`.
- If you have no Dashboard token, leave a one-line note for the owner. Do not invent a Management API call that needs secrets.

**4. Phase 6 — held-number **timer** (do not Telnyx-delete)**

- Endpoint exists: `GET /api/cron/release-held-numbers` with `Authorization: Bearer $CRON_SECRET`.
- After the detach commit, this job must **only detach**. Add a systemd timer (or document the exact unit files under `deploy/systemd/`) that hits localhost hourly.
- Install on the VPS only if you can without a sudo password. If not, commit the unit files and install steps in `docs/ops/RUNBOOK.md`.
- Do **not** one-shot-release Eve’s live `+16176137764` or Ash’s live `+13105847719`.

**5. Phase 4 prep (no submit)**

- Bump `mobile/pubspec.yaml` off `1.0.0+1` if you are sure no one is mid-build (or leave a note and skip if unsure).
- Draft store listing copy in a file (e.g. `.cursor/plans/store_launch/store_listing_draft.md`): presets only, no clone, privacy policy `https://echodesk.us/privacy`, support `echodesk2@gmail.com`.
- Do **not** create a Play keystore or upload IPA/AAB. Owner does signing.

**6. Small launch bugs you may fix if you hit them**

- `detach_phone_from_receptionist` used to set `phone_number=null` and Postgres rejected it (NOT NULL). The working-tree fix uses `""`. Confirm no other detach path still writes null.
- Eve’s `business_phone_numbers` row for `+16176137764` was `status=provisioning` with `telnyx_number_id` null — only fix if you can do it safely without breaking routing.
- Confirm `/get-started` after Phase 3 has **zero** git/run_prod strings (`rg run_prod landing`).

### Do not

- Submit App Store / Play.
- Turn `VOICE_CLONE_ENABLED` on.
- Build the web app.
- `git pull` on a dirty VPS tree; don’t `sudo rm` production `.env`.
- Force-push.
- Spend the session on first-reply delay or clone quality.

### When the owner returns

They will run `manual_prelaunch_tests.md` sections A–C on a **release** build against production. Tell them:

1. What you committed / pushed / deployed.
2. Whether get-started still has repo commands (should be no).
3. Whether landing deploy needs their sudo.
4. Whether the confirm-email template still needs a Dashboard paste.
5. Anything you did **not** finish from this list.

Update the Status table in `store_launch/plan.md` when a phase actually moves.

---

## Owner smoke later (not this agent)

New email, second phone, release build, `API_BASE_URL=https://echodesk.us`. Checklist A–C only. Ignore clone. Ignore first-reply delay.
