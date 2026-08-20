# Pocket TTS Hybrid + Voice Clone (Pre-Launch)

## Decision summary

| Choice | Decision |
|--------|----------|
| Live TTS default | **Google Neural2** (unchanged) |
| Pocket TTS role | **Voice cloning only** — VPS path |
| Dual path window | Keep dual path at least through **~10 paying customers** — **do not unify early** |
| Where clone UI lives | **Receptionist creation Step 5** (Call behavior), optional |
| Onboarding | No new onboarding step — same wizard, clone is skippable |
| VPS | Keep Clarity + EchoDesk on current **12 vCPU** box; Pocket as localhost sidecar |
| Metering | **Meter both** Google and Pocket (chars/ms/requests/fallbacks) so cost is visible by customer ~8–9 |
| Pocket / VPS down | **Required fallback:** degrade clone shops to stock Google preset + brief “using a stock voice for a minute” (never silent) |
| Full Google → Pocket swap | Deferred — revisit only **after** dual-path data at ~10+ customers (Phase 6) |

### Operating rule (through ~10 customers)

```text
Presets  → Google (cloud)     — always
Clones   → Pocket (this VPS)  — preferred
Unify?   → No. Not before we have metered evidence.
If VPS/Pocket dies → Google stock voice + short spoken notice. Never hang.
```

---


## UX: where “Clone your voice” lives

### Primary: Receptionist creation / first-run wizard

Onboarding already sends users into `CreateReceptionistScreen(firstRun: true)`. Voice selection is already **Step 5 — Call behavior** (`create_receptionist_screen.dart`).

**Put clone there as an optional path under “Choose a voice”:**

```text
Step 5 — Call behavior
  ├─ Preset cards (Friendly, Professional, …)  ← default, Google
  └─ Optional card: “Use my voice”
        → Record / upload (~5–20s)
        → Consent checkbox
        → Pocket preview
        → Select as this receptionist’s voice
```

**Why here (not a separate onboarding step):**

- Voice is already part of receptionist setup; clone is “another voice option,” not a new account phase.
- First-time onboarding stays fast: calendar → receptionist → number → test call.
- Cloning requires quiet audio + consent; forcing it mid-onboarding increases drop-off.
- Same screen works for first receptionist and later ones.

### Secondary: Receptionist settings (after create)

Same control in the receptionist voice/settings tab (`instructions_tab` / voice section) so users can:

- Add a clone later
- Switch back to a Google preset
- Re-record a clone

### Explicitly not recommended for v1

- Dedicated onboarding checklist step (“Clone voice” before receptionist)
- Account-level “one voice for all receptionists” only (store clone at org/user level, but **bind per receptionist** so multi-location stays flexible)
- Replacing Google presets before launch

---

## Architecture (hybrid)

```text
Receptionist
  voice_preset_key = friendly_warm | …     → Google Neural2 (live + preview)
  voice_clone_id   = <uuid> | null         → if set, Pocket for live + preview

Call / preview path
  resolve_tts_voice(...)
    if voice_clone_id:
      try Pocket sidecar → μ-law 8k / MP3
      on failure/timeout/unhealthy → Google stock preset + one-time spoken notice
    else:
      Google (current facade)

Meter every synth (both providers):
  provider, receptionist_id, clone_id?, chars, synth_ms, cache_hit, fallback_used
```

Preset keys stay stable. Do **not** remap presets to Pocket until Phase 6 is explicitly opened with metering evidence.

**Fallback copy (clone path only, once per call or once per outage window):**  
something like: “Sorry — I’m using a backup voice for a minute.” then continue on the receptionist’s saved Google preset (or `professional_calm` if none).

---


## Phases

### Phase 0 — VPS spike (go/no-go)

**Goal:** Prove Pocket on the live box before product work.

- [x] Install Pocket TTS on Contabo (`clarity` / `209.126.87.50`); keep model warm via systemd sidecar on localhost
- [x] Measure warm first-chunk latency; convert to μ-law 8 kHz and MP3
- [x] Catalog voice → `.safetensors` → phone-path preview (custom wav blocked until HF_TOKEN)
- [x] Stress 1 / 2 / 4 concurrent synths on 12 vCPU; pick a concurrency cap (start at 2–4)

**Exit:** Warm first audio acceptable (&lt; ~400ms target budget for TTS alone) and phone quality OK.

**Do not proceed to UI if spike fails.**

---

### Phase 1 — Backend provider seam

**Goal:** Facade can route clone voices to Pocket without touching Google presets.

- [x] Add `backend/voice/pocket_tts.py` (HTTP client to sidecar)
- [x] Extend `ResolvedTtsVoice` with `provider` (`google` | `pocket`) and clone/path fields
- [x] Branch in `tts_facade.py`: clone → Pocket; else Google
- [x] Add optional `pocket_voice` entries on preset rows in `voice_presets.py` (unused until Phase 6)
- [x] Config: `POCKET_TTS_URL`, `POCKET_TTS_ENABLED`, concurrency / timeout; keep `TTS_PROVIDER` semantics for later default flip only
- [x] **Hard requirement — clone fallback:** if Pocket unhealthy / timeout / error → speak short stock-voice notice once → continue on Google preset for that call (log `fallback_used=true`). Never leave clone shops silent.
- [x] **Metering from day one:** structured log (or counter) per synth for `google` and `pocket`: chars, synth_ms, cache_hit, fallback_used — enough to compare cost/latency by customer ~8–9

**Key files:** `tts_facade.py`, `voice_presets.py`, `google_tts.py` (unchanged path), `config.py`

---

### Phase 2 — Clone storage + API

**Goal:** Users can create/list/delete clones; receptionist can bind one.

- [x] Migration: `voice_clones` table (`id`, `user_id`/`org`, `label`, `embedding_path`, `consent_at`, `created_at`, …)
- [x] Receptionist column: `voice_clone_id` nullable (FK); when set, live TTS uses Pocket
- [x] `POST /api/mobile/voice-clones` — upload audio → `export-voice` → store under `/opt/echodesk/voices/{user_id}/`
- [x] `GET` list, `DELETE`, preview endpoint (MP3 via Pocket)
- [x] Create/update receptionist accepts `voice_clone_id` (clears or coexists with `voice_preset_key` per rule: clone wins when set)
- [x] Consent required on create; reject without it
- [x] Disk + auth checks (owner-only access to embeddings)

---

### Phase 3 — Mobile UI (wizard + settings)

**Goal:** Optional “Use my voice” in the existing voice step.

#### Receptionist creation — Step 5

- [x] Keep existing Google preset list + preview
- [x] Add optional **Use my voice** card/section (not a new wizard step)
- [x] Flow: record or upload → consent → upload → Pocket preview → select
- [x] Selecting a preset clears `voice_clone_id`; selecting clone sets `voice_clone_id` and may keep last preset as fallback metadata
- [x] Skip always allowed (default remains a Google preset)

#### Settings (post-create)

- [x] Same clone controls on receptionist voice settings
- [x] Allow switch clone ↔ preset without recreating receptionist

#### Onboarding

- [x] No new onboarding phase in `onboarding_screen.dart`
- [x] First-run still opens create receptionist; clone remains optional inside Step 5
- [x] Copy can mention “optional: use your own voice” without blocking progress

---

### Phase 4 — Ops / launch hardening

- [x] systemd unit for Pocket sidecar; restart policy; not exposed publicly
- [x] Health: `/health` or internal check reports `pocket_tts` status when enabled (drives fallback fast, not only on synth error)
- [x] Concurrency semaphore / queue; never starve Clarity Rex on same host (nice/cgroup optional)
- [x] **Dual-path metering dashboard/logs:** Google vs Pocket volume, latency, estimated Google $ (chars), Pocket CPU/fallback rate — review around customers 8–9
- [x] Alert or log spike when `fallback_used` rises (VPS/Pocket degradation)
- [x] Docs: `ENV.md` keys; short runbook for voice clone disk growth + “Pocket down → stock voice” behavior

---

### Phase 5 — Launch positioning (product)

- [ ] Marketing: five professional voices + **optional clone your voice**
- [ ] Do not claim “we replaced Google TTS” or a single unified engine
- [ ] Support notes: sample quality tips (quiet room, 5–20s, no music); if clone voice drops to stock, that’s expected during VPS issues

---

### Phase 6 — Unify later (only after dual-path evidence) — deferred

**Gate:** do not open until **≥ ~10 paying customers** and metering shows a clear reason (cost, ops, or quality). Dual path through customer 10 is intentional.

- [ ] Review Google $ vs Pocket CPU/fallback rate from metering
- [ ] Only then decide: stay hybrid, or map presets → Pocket
- [ ] If unifying: flag / % rollout; keep Google fallback; clones already on Pocket
- [ ] Optional one-time “voice upgraded” notice for preset users

---

## Acceptance criteria (pre-launch done when)

1. New user completes onboarding **without** cloning.
2. In Step 5, user can pick a Google preset (current behavior).
3. User can optionally clone, preview, and bind voice to receptionist.
4. Test call with **preset** = Google path.
5. Test call with **clone** = Pocket path (μ-law to Telnyx).
6. With Pocket stopped/unhealthy: clone receptionist still speaks via **Google stock + brief notice** (not silent).
7. Logs/metrics distinguish Google vs Pocket synths (chars, ms, fallbacks).
8. Clarity + EchoDesk remain healthy on the shared VPS under light concurrent clone synth.

---

## Out of scope (v1)

- Separate VPS for EchoDesk vs Clarity
- Unifying / replacing Google presets before ~10 customers
- Fine-tuning / training custom models (zero-shot embedding only)
- Browser WebGPU Pocket client

---

## Suggested build order

```text
Phase 0 spike → Phase 1 facade → Phase 2 API/DB → Phase 3 mobile Step 5 + settings → Phase 4 ops → launch
                                                                              Phase 6 much later
```

## Status

| Phase | Status |
|-------|--------|
| 0 Spike | Passed (latency/phone-path). Custom wav clone needs `HF_TOKEN` |
| 1 Facade | Done |
| 2 Clone API | Done |
| 3 Mobile UI | Done |
| 4 Ops | Done (user sidecar; system unit needs root) |
| 5 Launch copy | Not started |
| 6 Unify (post-~10 + metering) | Deferred — do not open early |

### Phase 0 notes (2026-08-19, `clarity` 12 vCPU)

- Installed `pocket-tts==2.1.0` in `/home/rex/pocket-tts-spike/.venv`. Official `serve` cannot load local `.safetensors`; EchoDesk uses `deploy/pocket-tts/sidecar.py`.
- Warm first-chunk (alba, n=5): median **293.5ms** (min 251, max 484). Under 400ms after warmup.
- Phone path: 24 kHz → μ-law 8 kHz + MP3. Convert ~4ms. RTF ~0.90 on a ~4.7s line.
- Safetensors reload of a catalog voice: **2.2ms**.
- Custom wav clone **failed**: cloning weights are HF-gated. Accept https://huggingface.co/kyutai/pocket-tts and set `HF_TOKEN` on the sidecar.
- Concurrency cap **2** (model is not thread-safe; shared box with Clarity Rex).
- Sidecar bind: `127.0.0.1:8100`.

---

## Related code (current)

- Voice presets / resolve: `backend/voice_presets.py`
- TTS facade: `backend/voice/tts_facade.py`, `backend/voice/google_tts.py`
- Wizard voice UI: `mobile/lib/screens/receptionists/create_receptionist_screen.dart` (Step 5)
- Wizard model: `mobile/lib/models/wizard_form.dart` (`voicePresetKey`)
- Onboarding entry: `mobile/lib/screens/onboarding/onboarding_screen.dart` → create receptionist
- Mobile preset APIs: `backend/api/mobile_routes.py` (`/voice-presets`, preview)
