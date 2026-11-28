# Environment variables

Loaded via Pydantic **`Settings`** in `backend/config.py` from project root **`.env`** / **`.env.local`**. Names below are the **environment variable** names (UPPER_SNAKE_CASE).

## Telnyx (telephony + SMS)

| Variable | Purpose | Example | Common misconfig |
|----------|---------|---------|------------------|
| **`TELNYX_API_KEY`** | Bearer token for Voice API (answer, stream, record) and Messages API (SMS). **Required** at startup (`validate_telnyx`). | `KEY0123...` | Missing → voice webhook fails fast; 401 from Telnyx. |
| **`TELNYX_WEBHOOK_BASE_URL`** | Public **https** origin for building **`stream_url`** (`wss://…/api/voice/stream?…`) and default SMS **`webhook_url`** (`{base}/api/telnyx/sms`). | `https://voice.example.com` | Trailing slash usually OK (code strips). Wrong host → Telnyx cannot open media WebSocket or SMS webhooks. |
| **`TELNYX_STREAM_BASE_URL`** | Optional **alternate** origin for **WebSocket only** when media must hit a different hostname than HTTP webhooks. | `https://stream.example.com` | If unset, **`TELNYX_WEBHOOK_BASE_URL`** is used. |
| **`TELNYX_PUBLIC_KEY`** | Telnyx Ed25519 public key material for **`telnyx-signature-ed25519`** verification on webhooks. | (from Telnyx portal) | Wrong key → **403** on `/api/telnyx/*`. |
| **`TELNYX_WEBHOOK_SECRET`** | Shared secret for **HMAC** webhook verification when Ed25519 headers are unavailable. | long random string | Must match Telnyx app “secret” if using HMAC fallback. |
| **`TELNYX_SKIP_VERIFY`** | If true, allows webhooks when **Ed25519 headers are missing** (e.g. proxy stripped). **Defense in depth:** **`TELNYX_ALLOWED_IPS` must be non-empty** or requests are rejected. | `1` / `true` | Enabling without **allowlist** → startup warning and **403**; enabling without understanding → open webhooks. |
| **`TELNYX_ALLOWED_IPS`** | Comma-separated **exact IPs and/or CIDR blocks** for clients allowed when verification is skipped or as IP check in skip path. Parsed with **`ipaddress`** (Python). | `192.76.120.0/24,203.0.113.10` | Empty under **`SKIP_VERIFY`** → reject. Wrong CIDR → legitimate Telnyx egress blocked. **Note:** behind **`X-Forwarded-For`**, ensure your reverse proxy sets the real client IP correctly. |
| **`TELNYX_CONNECTION_ID`** | Telnyx **Call Control Application** connection id for **outbound** calls (`/api/telnyx/outbound`). | UUID from portal | Missing → outbound route errors. |
| **`TELNYX_ALLOW_RECEPTIONIST_FALLBACK`** | If **true**, unmatched DID uses **first active** receptionist (dangerous). Default **false**. | `0` | Leave **false** in production to catch DID misconfiguration. |
| **`TELNYX_ENABLE_RECORDING`** | If **true** (default), sends **`record_start`** on answered calls. | `true` | `false` → no recording attempts. |

## Voice AI

| Variable | Purpose | Example | Common misconfig |
|----------|---------|---------|------------------|
| **`DEEPGRAM_API_KEY`** | Live transcription (server). **Required** (`validate_voice_keys`). | | Missing → WebSocket closes **1011** “Server misconfiguration”. |
| **`GROK_API_KEY`** | xAI Grok for chat / tool use. **Required**. | | Missing → same as Deepgram. |
| **`VOICE_SERVER_API_KEY`** | Shared secret for **`/api/receptionist-prompt`** and **`/api/voice/calendar`** (headers **`x-voice-server-key`** or **`x-voice-api-key`**). | long random | Missing → prompt/calendar not wired from stream handler. Mismatch → **401**. |
| **`VOICE_PROMPT_BASE_URL`** | Base URL of the app that serves prompts (often Next.js). Handler falls back to **localhost:PORT** only if unset. | `https://app.example.com` | Wrong URL → default greeting/prompt or fetch failures. |
| **`VOICE_DUMMY_TEST`** | **`1`** — sends dummy audio instead of real pipeline (debug only). | unset in prod | |
| **`SKIP_GOOGLE_TTS_VALIDATION`** | **`1` / true** — skip Google credential check at startup. | | Only for CI/dev without ADC. |

## Google TTS and Calendar

| Variable | Purpose | Example | Common misconfig |
|----------|---------|---------|------------------|
| **`GOOGLE_APPLICATION_CREDENTIALS`** | Path to service account JSON for **Text-to-Speech** (and other Google APIs using ADC). | `/secrets/tts.json` | Missing/invalid → startup validation failure (unless skip flag). |
| **`GOOGLE_CLIENT_ID`**, **`GOOGLE_CLIENT_SECRET`**, **`GOOGLE_REDIRECT_URI`** / **`NEXT_PUBLIC_GOOGLE_REDIRECT_URI`** | OAuth for user calendar linking. | | Wrong redirect → OAuth errors in app (not voice stream). |
| **`TTS_PROVIDER`** | Live default remains **`google`**. Do not flip to Pocket before Phase 6. | `google` | Changing this does not route clones; clones use **`POCKET_TTS_ENABLED`**. |
| **`VOICE_CLONE_ENABLED`** | Product switch for “Use my voice”. **Off for store launch.** When false, clone UI stays hidden and live calls ignore `voice_clone_id` (Google preset only). | `false` | Turn on later with `POCKET_TTS_ENABLED` after clone quality is launch-ready. |
| **`POCKET_TTS_ENABLED`** | When true, receptionists with **`voice_clone_id`** synthesize via the localhost Pocket sidecar. Presets stay on Google. | `false` | Enable only after the sidecar is healthy **and** `VOICE_CLONE_ENABLED` is true. |
| **`POCKET_TTS_URL`** | Sidecar origin (localhost only). | `http://127.0.0.1:8100` | Must not be public. |
| **`POCKET_TTS_TIMEOUT_SECONDS`** | HTTP timeout for sidecar synth / export. | `30` | Too low → clone fallback to Google. |
| **`POCKET_TTS_CONCURRENCY`** | Documented cap (sidecar enforces). Start at **2** on the shared 12 vCPU box. | `2` | Higher values starve Clarity Rex. |
| **`POCKET_TTS_VOICES_DIR`** | Canonical clone embedding directory (`{dir}/{user_id}/{clone_id}.safetensors`). | `/opt/echodesk/voices` | Sidecar writes files; backend stores the returned path. |
| **`HF_TOKEN`** | Hugging Face token for Pocket **voice-cloning weights** (gated). Required on the sidecar process, not EchoDesk. | | Without it, export-voice returns 503. Accept terms at https://huggingface.co/kyutai/pocket-tts |

Additional **`GOOGLE_TTS_*`**, **`TTS_*`** caps, cache, and retry knobs are in `config.py` (optional tuning).

**Clone fallback:** if Pocket is unhealthy, times out, or errors, EchoDesk speaks a one-time notice (“Sorry — I’m using a backup voice for a minute.”) then continues on the receptionist’s Google Neural2 preset for that call. Never silent. Logs: `[TTS_METER] fallback_used=true` and `[TTS] pocket_fallback_spike` if 5+ fallbacks in 5 minutes.

## Supabase

| Variable | Purpose | Example | Common misconfig |
|----------|---------|---------|------------------|
| **`NEXT_PUBLIC_SUPABASE_URL`** | Canonical Supabase URL (**preferred**). | `https://xxx.supabase.co` | |
| **`SUPABASE_URL`** | Deprecated alias; still read if canonical unset. | | Triggers deprecation warning. |
| **`SUPABASE_SERVICE_ROLE_KEY`** | Server-side DB/admin access. **Required**. | | Missing → startup **`validate_supabase`** fails. |
| **`NEXT_PUBLIC_SUPABASE_ANON_KEY`** | JWT validation for mobile routes. **Required**. | | Missing → startup failure. |

## Stripe, Firebase, cron, app URLs

Used by billing, push, and redirects — see `config.py` for full list: **`STRIPE_SECRET_KEY`**, **`STRIPE_WEBHOOK_SECRET`**, **`FIREBASE_SERVICE_ACCOUNT_KEY`**, **`CRON_SECRET`**, **`APP_API_BASE_URL`** / **`NEXT_PUBLIC_APP_URL`**, **`INTERNAL_API_KEY`**, **`SENTRY_DSN`**, **`PORT`**, etc.

## Apple In-App Purchase

Required before iPhone purchases can activate an account. Apply migration `supabase/migrations/047_apple_billing_source.sql` before deploying the backend that writes these columns. Never commit the `.p8` key.

| Variable | Purpose |
|----------|---------|
| **`APPLE_ISSUER_ID`** | Issuer ID from App Store Connect → Users and Access → Integrations. |
| **`APPLE_KEY_ID`** | Key ID of the In-App Purchase API key. |
| **`APPLE_PRIVATE_KEY`** | Contents of the downloaded `.p8`. Newlines may be written as `\n`. |
| **`APPLE_PRIVATE_KEY_PATH`** | Alternative to `APPLE_PRIVATE_KEY`: absolute path to the `.p8` on the server. |
| **`APPLE_BUNDLE_ID`** | App bundle id. Default `com.echodesk.echodeskMobile`. |
| **`APPLE_IAP_ENVIRONMENT`** | `sandbox` or `production`. The server still accepts the other environment when the JWS signature verifies, so one URL can receive both notification streams. |
| **`APPLE_APP_APPLE_ID`** | Numeric App Store app id. Required to verify Production transactions. Sandbox verification works without it. |
| **`APPLE_ROOT_CA_PATH`** | Optional directory of Apple root `.cer` files. Default is `backend/certs/apple/`. |
| **`APPLE_IAP_ONLINE_CHECKS`** | `true` to also run OCSP checks. Signature verification against Apple's roots always runs. Default `false`. |
| **`APPLE_IAP_ALLOW_XCODE`** | `true` only for local StoreKit testing. Leave unset in production. Xcode payloads are not signed by Apple. |
| **`APPLE_IAP_PRODUCT_STARTER`** | Default `com.echodesk.sub.starter.monthly` (250 minutes). |
| **`APPLE_IAP_PRODUCT_GROWTH`** | Default `com.echodesk.sub.growth.monthly` (750 minutes). |
| **`APPLE_IAP_PRODUCT_BUSINESS`** | Default `com.echodesk.sub.business.monthly` (1,500 minutes). |

The iOS build can override the same product ids with `--dart-define=APPLE_IAP_PRODUCT_STARTER=...` (and `GROWTH` / `BUSINESS`). Notification URL: `https://echodesk.us/api/apple/notifications`. Client verification: `POST /api/mobile/apple/verify`. Setup steps for App Store Connect are in `mobile/APP_STORE_IAP_SETUP.md`.

## Quick reference — URLs Telnyx and clients call

| Endpoint | Use |
|----------|-----|
| **`{TELNYX_WEBHOOK_BASE_URL}/api/telnyx/voice`** | Voice Call Control webhooks |
| **`{TELNYX_WEBHOOK_BASE_URL}/api/telnyx/cdr`** | CDR / usage / recording events (when configured separately) |
| **`{TELNYX_WEBHOOK_BASE_URL}/api/telnyx/sms`** | Messaging status webhooks |
| **`wss://{host}/api/voice/stream?...`** | Media stream (`host` from **`TELNYX_STREAM_BASE_URL`** or **`TELNYX_WEBHOOK_BASE_URL`**) |

Replace `https://` with `wss://` and `http://` with `ws://` automatically in code (`get_telnyx_ws_base`).
