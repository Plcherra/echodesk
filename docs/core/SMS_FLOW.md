# SMS flow

Code: `backend/telnyx/sms.py` (send), `backend/telnyx/sms_webhook.py` (webhook), `backend/calendar_api/_booking.py` (post-booking send), `backend/telnyx/sms_delivery_registry.py` (in-process status for the voice call).

## Send path

1. **`handle_create_appointment`** (after a successful calendar write) may build a confirmation body and call **`send_sms(to_number, from_number, text)`**.
2. **`from_number`** comes from receptionist/SMS configuration in Supabase (`_resolve_sms_from_number`); **`to_number`** is the normalized caller phone when valid E.164.
3. HTTP **POST** `https://api.telnyx.com/v2/messages` with Bearer **`TELNYX_API_KEY`**.
4. If **`TELNYX_WEBHOOK_BASE_URL`** is set, the JSON body includes **`webhook_url`** = `{base}/api/telnyx/sms` so Telnyx can report delivery lifecycle events.

**Outcome fields (API layer, returned inside `sms_followup` to the voice pipeline)**

- **`attempted`** — we tried to send (had from/to/text and entered the send path).
- **`api_accepted`** — Telnyx returned **success** and we parsed a response; **`false`** means HTTP error or exception (`telnyx_message_id` may be missing).
- **`telnyx_message_id`** — id used to correlate webhooks and DB rows.
- **`from_number_is_toll_free`** — heuristic for +1 8XX; used in spoken disclaimers if delivery fails.

On **`api_accepted`** with an id and **`appointment_id`**, **`store_sms_sent`** inserts a row into **`sms_messages`** (`status` initially **`sent`**).

## Webhook path

**`POST /api/telnyx/sms`** — same verification chain as other Telnyx webhooks (`voice_webhook_verify`).

Handled **`event_type`** values:

- **`message.sent`** — acknowledged; no DB update required for the MVP path (insert already happened on send).
- **`message.finalized`** — read per-recipient **`status`** from the payload, map to our canonical strings, then:
  - **`record_delivery_status(message_id, status)`** — updates the **in-memory** registry (same process as the voice worker — used for immediate post-booking TTS wording).
  - **`sms_messages` update** by **`telnyx_message_id`**: `status`, `updated_at`, optional `provider_status_detail`, `provider_errors`.

Mapped statuses include: **`delivered`**, **`delivery_failed`**, **`sending_failed`**, **`delivery_unconfirmed`**, **`sent`**, and Telnyx **`queued` / `sending`** → stored as **`sent`**.

## Database lifecycle (`sms_messages`)

| Phase | Typical `status` |
|-------|-------------------|
| Row inserted after successful API send | **`sent`** |
| Finalized — still in flight / carrier pending | **`sent`** or Telnyx-specific intermediate |
| Delivered to handset | **`delivered`** |
| Failed | **`delivery_failed`** or **`sending_failed`** |

Rows may be missing for messages sent before tracking existed — webhook logs **`no matching row`**.

## Meaning of terms

- **`api_accepted`** — Telnyx **accepted the REST request** to send; not proof of handset delivery.
- **`delivered`** — Telnyx **`message.finalized`** reported **`delivered`** for the recipient; best-effort carrier confirmation.
- **`delivery_failed`** — finalized as failed (carrier block, invalid number, policy, etc.). Logs may flag **toll-free** senders that need verification in Telnyx.

## US 10DLC (long codes)

Sending SMS from **US long-code** numbers to US handsets generally requires **10DLC brand/campaign registration** with carriers (and provider-side setup in Telnyx). This is a **carrier and compliance dependency**, not enforced or automated in this repository. If delivery fails for long-code traffic, verify **10DLC registration**, number capabilities, and Telnyx messaging profile status in the provider console.

EchoDesk is a platform, so customer-facing appointment SMS must be registered under the **business that owns the customer relationship**, not under one shared EchoDesk campaign. An EchoDesk-owned campaign can be used for EchoDesk-to-account-owner messages only, such as product, setup, billing, or support notifications to EchoDesk users.

For appointment/customer SMS, each business should have its own 10DLC brand/campaign and message flow. The message flow should identify the exact opt-in path, such as verbal consent during a scheduling call or inbound SMS to the published business number, and include the required disclosure: message frequency varies, message and data rates may apply, reply STOP to opt out, and reply HELP for help.

## Other entry points

**`api/appointment_followup.py`** can send follow-up SMS and also calls **`store_sms_sent`** when configured — same webhook and `sms_messages` pattern.
