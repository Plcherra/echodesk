# Runbook

FastAPI app: `backend/main.py`. Search logs with the **`[TURN_GUARD]`**, **`[CALL_DIAG]`**, **`[CAL_BOOK]`**, **`[SMS_WEBHOOK]`**, and **`[CALL_DIAG]`** (CDR) prefixes where noted.

## User hears nothing (check this first)

This is the **user-trust invariant**: a committed caller turn must yield **audible TTS** or an **explicit terminal** outcome (cancel / guard skip / low-confidence skip), not silence.

1. Find the call’s **`call_control_id`** (WebSocket query `call_sid` on `/api/voice/stream`).
2. In voice logs, locate **`[TURN_GUARD] commit_enqueued commit_id=N`** for that call window.
3. For that **`commit_id`**, confirm one of the following (in order):
   - **`[turn] TTS started commit_id=N`** — assistant spoke (includes `pre_ack`, `pre_tool_filler`, template response, `error_apology`, etc.).
   - **`dispatch_cancelled`** with **`commit_id=N`** — caller kept talking; new speech won.
   - **`dispatch_skipped reason=guard_reject`** or **`low_confidence`** with **`commit_id=N`** — intentional no-reply for that text.
   - **`dispatch_skipped reason=queued_*`** with **`commit_id=N`** — turn queued; later you must see **`dispatch_started path=queued_flush`** then **`path=process`** and then TTS or a terminal skip for the **same** `commit_id`.
4. **Invalid pattern (critical):** **`dispatch_started path=process commit_id=N`** with **no** matching **`[turn] TTS started commit_id=N`** and **no** terminal **`dispatch_skipped`** for that id afterward. Run **`./scripts/health-monitor.sh`** on recent PM2 logs to surface this automatically.
5. If TTS logs exist but the caller heard nothing, suspect **Telnyx stream / media** (not Grok): **`TELNYX_STREAM_BASE_URL`**, WebSocket errors **`[voice/stream]`**, or Telnyx **`90046`** / early hangup.

Use **`./scripts/health-monitor.sh`** (see **Health monitoring** below) for a quick Critical/Warnings/Healthy summary over the last tail of logs.

## Production readiness gate

Run through this before shipping to production. If any **must-pass** item fails, do not deploy until resolved or explicitly accepted.

### A. Core call path

- Inbound call answers; greeting plays.
- Caller can request availability; fast path responds quickly (watch **`[BOOKING_LATENCY]`**; see health monitor thresholds).
- Slot-style selection (e.g. “three PM”) can book without unnecessary LLM delay when slots were offered (**`slot_selection_fast_path_selected`**).
- Verbal confirmation plays after booking when expected.
- **`call_logs`** row exists for the call; outcome/recording fields sane.

### B. SMS truth

- Messages API accepts send when configured; webhook receives **`message.finalized`** when **`webhook_url`** is set.
- Final status in **`sms_messages`** reaches **`delivered`**, **`delivery_failed`**, or a known non-delivered state — not “delivered” on **`api_accepted`** alone.
- Spoken wording follows pipeline rules: never claim handset delivery on **`api_accepted`** only (see **`SMS_FLOW.md`**).
- **10DLC / carrier** compliance understood for US long codes (external to repo).

### C. Voice stability

- Every **`commit_enqueued`** has a **resolved** outcome: see **System invariants** (including **`dispatch_started` + `dispatch_skipped`** as valid when both apply to the same `commit_id`).
- No stuck **`is_processing`** across turns: queued turns flush via **`queued_flush`**.
- No overlapping turns dropping dispatch without a log line (grep **`[TURN_GUARD]`**).

### D. Infra

- **PM2** process healthy after restart (`callbot-voice`).
- **`TELNYX_ALLOWED_IPS`** correct when using skip-verify path; voice + CDR + SMS webhooks return **200** for valid signed/allowed traffic.
- Env URLs match live domain: **`TELNYX_WEBHOOK_BASE_URL`**, **`TELNYX_STREAM_BASE_URL`** (or derived stream URL).

### E. Regression

- **`pytest backend/tests`** passes locally / CI.
- Optional: **`cd mobile && flutter analyze`** before mobile release.
- Canonical docs still match shipped behavior (**`scripts/check-docs.sh`** passes).

## Health monitoring

**Script:** from repo root, `./scripts/health-monitor.sh` (uses **`TAIL_LINES`**, **`PM2_LOG_DIR`**, **`PM2_OUT_LOG`**, **`PM2_ERR_LOG`**; auto-picks `callbot-voice-out-0.log` / `callbot-voice-error-0.log` when present, else unsuffixed or newest `callbot-voice-out*.log` / `callbot-voice-error*.log`, then tails ~12k lines of each).

**Cron example (every 30 minutes):**

```bash
*/30 * * * * cd /path/to/repo && ./scripts/health-monitor.sh >> ~/health-monitor.log 2>&1
```

**What it highlights**

- **Critical:** `commit_id` with **`dispatch_started path=process`** but no matching **`[turn] TTS started commit_id=`** and no terminal **`dispatch_skipped`** (guard/low) — silent user turn.
- **Warnings:** `commit_enqueued` with no `path=process` in the tail (often an incomplete window or still-queued turn); booking **`turn_end`** over thresholds; **`delivery_failed`** / **`sms_api_accepted_downstream_unknown`**; webhook verification failure logs; pipeline errors.
- **Counts:** recording saved log hits, enqueue/process/TTS correlation stats.

**Webhook routing (Telnyx → this app)**

| Endpoint | Role |
|----------|------|
| **`POST /api/telnyx/voice`** | Call control: answer, streaming, recording start, etc. |
| **`POST /api/telnyx/cdr`** | CDR: hangup, cost, **`call.recording.saved`** → DB **`recording_url`** / status |
| **`POST /api/telnyx/sms`** | Messaging: **`message.finalized`** → **`sms_messages`** + in-call delivery hints |

Verification failures log **`client_ip`** (structured) — grep **`Telnyx webhook verification failed`** / **`webhook_verification_outcome`**.

**Recording lifecycle (MVP)**

- Consent / config → **`record_start`** when enabled.
- On hangup, **`call_logs.recording_status`** may move to **`processing`** when consent was played and status was empty.
- **`call.recording.saved`** sets **`recording_status`** to **`available`** (or **`failed`** if no URL) and fills **`recording_url`** when present.
- **Operational invariant:** rows stuck **`processing`** longer than **~15–30 minutes** after call end should be investigated (Telnyx, retention, or missing CDR event).

## System invariants

- **Dispatch / commit_id:** Every **`commit_enqueued`** must eventually reach a **resolved** outcome. **`dispatch_started path=process`** plus later **`dispatch_skipped reason=guard_reject`** or **`low_confidence`** (same **`commit_id`**) is **valid** — do not treat as missing terminal. **`dispatch_skipped reason=queued_*`** is **not** final until **`queued_flush`** + **`path=process`** completes that id.
- **User spoke → system responds:** After **`path=process`** for a **`commit_id`**, require **`[turn] TTS started commit_id=`** or terminal skip for that id (see **User hears nothing** above).
- **Queue:** Turns **`queued_for_after_processing`** / **`queued_after_debounce`** must drain via **`dispatch_started path=queued_flush`**; they must not disappear without logs.
- **Slots:** When **`resolve_slot_selection`** returns **`ok`** with **`slot_iso`** from last-offered slots, booking uses the fast tool path — not silent fallback to LLM for that resolution (ambiguous cases log **`slot_selection_fallback_to_llm`**).
- **SMS:** **`api_accepted`** is not handset **`delivered`**; TTS uses the pipeline helper so wording stays truthful.
- **Recording:** **`available`** must not regress to **`processing`** on hangup finalize (see tests around **`cdr_webhook`**); **`call.recording.saved`** should persist **`recording_url`** when Telnyx provides one.
- **Post-booking:** Deterministic post-booking reply or LLM path must not exit without audio when a response is required; errors still hit the generic apology TTS path with a logged **`[turn] TTS started … (error_apology)`**.

## Pocket TTS voice clones (hybrid)

Pocket is a **localhost sidecar** on the shared Clarity + EchoDesk VPS (`127.0.0.1:8100`). Google Neural2 remains the default for presets.

**Fallback:** clone synth failure or unhealthy sidecar → one spoken notice (“using a backup voice for a minute”) then Google preset for the rest of the call. Logs: **`[TTS_METER]`** (`provider`, `chars`, `synth_ms`, `cache_hit`, `fallback_used`), **`pocket_fallback_used`**, **`pocket_fallback_spike`**.

**Health:** `GET /api/health` includes **`pocket_tts`** only when **`POCKET_TTS_ENABLED=true`**.

**Sidecar (user `echodesk`, no public bind):**

```bash
sudo systemctl status pocket-tts --no-pager
curl -fsS http://127.0.0.1:8100/health
```

Install / relocate from the Phase 0 spike: `sudo bash deploy/scripts/install-pocket-tts.sh`.
Unit: `deploy/systemd/pocket-tts.service`. Files: `/opt/echodesk/pocket-tts`, clones: `/opt/echodesk/voices`.
HF token: `/opt/echodesk/pocket-tts/hf.env` (mode 600). Do not put `HF_TOKEN` in the EchoDesk app `.env`.

**Disk growth:** embeddings are ~6MB each under `POCKET_TTS_VOICES_DIR/{user_id}/`. Delete clones via the mobile API; the sidecar removes the file. Audit leftover `.safetensors` if users churn.

**Cloning gated:** accept https://huggingface.co/kyutai/pocket-tts and set **`HF_TOKEN`** on the sidecar, then restart. Until then, catalog/safetensors playback works; `POST /export-voice` returns 503.

## No response from the assistant

**Where to look**

- Voice backend logs for the **`call_control_id`** (query param `call_sid` on `/api/voice/stream`).
- WebSocket: **`[voice/stream]`** accept/handler errors; ASGI **`[asgi] WebSocket`**.

**What to search**

- **`[TURN_GUARD] dispatch_cancelled`** — caller kept talking; debounce/Grok cancelled. If constant, check duplicate audio / echo or VAD.
- **`[TURN_GUARD] dispatch_skipped reason=guard_reject`** or **`low_confidence`** — utterance too short, filler-only, or STT confidence &lt; 0.35.
- **`[TURN_GUARD] incomplete_transcript_wait`** — pipeline is waiting for more words (dangling phrase).
- **`dispatch_started`** without **`[turn] TTS started`** — rare; check exceptions **`[voice/stream] Pipeline error`** or Grok/API failures.
- **`Pipeline init failed`** / **`Server misconfiguration`** — missing **`DEEPGRAM_API_KEY`** / **`GROK_API_KEY`** closes the socket early.

**Likely causes**

- Truncated speech or poor audio → low confidence or empty finals.
- **`TELNYX_STREAM_BASE_URL` / `TELNYX_WEBHOOK_BASE_URL`** wrong → stream never connects or wrong host.
- Upstream LLM or calendar timeout (see booking section).

## SMS not delivered

**Where to look**

- **`[CAL_BOOK] sms_followup_sent`** — `success`, `telnyx_status`, `telnyx_msg_id`, `telnyx_error`.
- **`[TELNYX_SMS] send_failed`** — HTTP error from Messages API.
- **`[SMS_WEBHOOK] message.finalized`** — final `status` and **`delivery_failed`** warnings.
- Supabase **`sms_messages`** for the **`telnyx_message_id`**.

**What to search**

- **`api_accepted`** false in API responses vs **`success: true`** in logs — key mismatch.
- **`delivery_failed`** + toll-free warnings — unverified toll-free sender.
- **`no matching row`** on webhook — send path didn’t insert tracking (or wrong id).

**Likely causes**

- **10DLC / campaign** not approved for US long-code (external).
- **From number** not SMS-capable or wrong messaging profile in Telnyx.
- **Webhook URL** missing or **`TELNYX_WEBHOOK_BASE_URL`** wrong → no finalized updates (delivery state stays unknown in DB).
- Invalid **`to`** (normalization failed) — booking may succeed but SMS skipped; see **`[CAL_BOOK] sms_followup_diag`**.

## Booking slow or wrong time

**Where to look**

- **`[BOOKING_LATENCY]`** and **`[CALL_DIAG] slot_selection_*`** / **`fast_path_selected`**.
- **`[CAL_BOOK] create_appointment`** success vs error logs.

**What to search**

- **`slot_selection_fast_path_selected`** — deterministic slot picked from last availability.
- **`slot_selection_ambiguous`** / **`fallback_to_llm`** — two or more times matched; expect clarification turn.
- **`is_new_availability_search_intent`** behavior — user said “another day” etc.; offered slots cleared logically on new **`check_availability`**.
- **`llm_fallback_used`** — template didn’t apply; full Grok+tools path (slower).

**Likely causes**

- Stale **offered slots** in memory vs what the assistant said — run **`check_availability`** again.
- Calendar **`slot_unavailable`** or timezone issues — see **`[CAL_BOOK]`** error type.
- **`VOICE_SERVER_API_KEY`** / **`VOICE_PROMPT_BASE_URL`** misconfigured — calendar tool calls fail or hit wrong app.

## Recording missing

**Where to look**

- Telnyx Mission Control / call **CDR** and recording objects for the **`call_control_id`**.
- Voice webhook logs **`recording_start`** success/failure: **`[CALL_DIAG] recording_start`**.
- **`POST /api/telnyx/cdr`** (or voice webhook forwarding **`call.recording.saved`**, **`call.hangup`**, etc.) — `backend/telnyx/cdr_webhook.py`.
- Supabase **`call_logs`**: **`recording_status`**, **`recording_url`**, consent flags.

**What to search**

- **`TELNYX_ENABLE_RECORDING`** disabled → no **`record_start`**.
- **`recording_consent_played`** / consent phrase path in **`handler.py`** — consent tracked for compliance.
- CDR **`call.recording.saved`** never arrived — Telnyx config, retention, or recording not enabled on connection.

**Likely causes**

- Recording disabled in env or Telnyx connection.
- Call too short; recording never finalized.
- Missing migrations for **`call_logs`** recording columns — startup warning in logs.

## Webhook / security rejects (voice, CDR, SMS)

**What to search**

- **`Webhook signature verification failed`**, **`429`** rate limit — **`voice_webhook_verify`**.
- **`TELNYX_SKIP_VERIFY`** with empty **`TELNYX_ALLOWED_IPS`** — startup warning; requests rejected when skip path requires allowlist.

**Likely causes**

- **`TELNYX_PUBLIC_KEY`** / **`TELNYX_WEBHOOK_SECRET`** doesn’t match Telnyx app.
- Proxy strips Ed25519 headers — must use **`TELNYX_SKIP_VERIFY`** **and** non-empty **`TELNYX_ALLOWED_IPS`** (CIDR supported).
