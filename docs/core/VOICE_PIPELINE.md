# Voice pipeline

Implementation: `backend/voice/pipeline.py` (Deepgram → Grok → TTS). WebSocket entry: `backend/voice/handler.py` → `run_voice_pipeline`.

Live TTS default is **Google Neural2**. If the receptionist has **`voice_clone_id`**, `resolve_tts_voice` sets `provider=pocket` and `tts_facade` calls the localhost Pocket sidecar (`backend/voice/pocket_tts.py`). Pocket failure falls back to the Google preset.

## Turn lifecycle

1. **Interim / streaming text** — Deepgram sends partial transcripts. Any **non–speech-final** transcript with text **cancels** pending debounce and in-flight Grok (`_cancel_pending_response`), so new speech wins over an old turn.
2. **Buffering finals** — On `is_final`, text is **appended** to `transcript_buffer`. Certain finals can trigger scheduling early (short whitelist while not yet `speech_final`).
3. **End of utterance** — `_schedule_trigger` runs on **`speech_final`** or **Deepgram `UtteranceEnd`** (with buffered finals).
4. **Commit candidate** — After guards, the pipeline logs **`commit_candidate`** with a reason and **`commit_enqueued`** with a monotonic `commit_id`. The committed text may differ from the last buffer chunk (e.g. **reuse of a recent “rich” transcript** within 8s when the new tail is a short whitelist phrase like “yes”).
5. **Dispatch** — Exactly one of the outcomes below must apply for every enqueue (no silent drops).

## Debounce rules

Constants (see code): **`DEBOUNCE_MS = 1200`**, **`DEBOUNCE_MS_FALLBACK = 800`** for utterances with **≤ 4 words** (unless immediate dispatch applies).

**What cancels a turn (before dispatch runs)**

- New **interim** transcript (not `speech_final`) — cancels debounce task and Grok task; logs **`dispatch_cancelled reason=new_speech_or_interim`**.
- **Replacing** a pending debounce — scheduling a new trigger cancels the previous **`asyncio.sleep`** debounce; completion handler logs **`dispatch_cancelled reason=debounce_task_cancelled`** if the task was cancelled.

**Incomplete utterances**

- If the stitched transcript looks **incomplete** (e.g. ends with “tomorrow at”, “for”, “can you”) **and** there is no **clear intent**, `_schedule_trigger` **returns without committing** — no dispatch for that trigger (caller is expected to continue speaking).

**Snapshot vs shared state**

- For debounced turns, **`snap_text` / `snap_conf` / `snap_id`** are captured when the debounce **starts**. The done callback applies those snapshots to `turn_complete_transcript` when the sleep finishes, so a later mutation of `transcript_buffer` does not change that committed turn.

**Confidence**

- **`MIN_CONFIDENCE = 0.35`**. Below that, dispatch is **`dispatch_skipped reason=low_confidence`** unless the text matches the **short utterance whitelist** (bypass logged).

## Queue behavior

- **`is_processing`** is True while `process_user_input` runs (Grok/TTS work for the current turn).
- If a new turn is ready while **`is_processing`**, it is **`pending_turn_queue`**’d — logs **`dispatch_skipped reason=queued_for_after_processing`** (immediate path) or **`queued_after_debounce`** (debounce path).
- When processing **finishes**, one queued item is moved into `turn_complete_transcript` and **`dispatch_started path=queued_flush`** runs.

## Slot selection (fast path)

Implementation: `backend/voice/slot_selection.py`. State: **`offered_slots_state`** in the pipeline (updated only when **`check_availability`** returns success — copies `exact_slots`, `suggested_slots`, `summary_periods`, and optional `last_date_text`).

Rules:

- Resolution uses **only** the **last offered** `exact_slots` or, if empty, `suggested_slots`. It **never invents** a time outside that list.
- **`is_new_availability_search_intent`** — phrases like “another day”, “check availability”, “what about monday”, etc. When True, **slot fast path is skipped** so the model can run a fresh **`check_availability`**.
- If **`resolve_slot_selection`** returns **`ok` with `slot_iso`**, the pipeline calls **`create_appointment`** with that `start_time` (plus fixed duration/summary flags) **without** waiting for the LLM.
- If resolution is **`ambiguous`** (e.g. two times match), logs note **fallback to LLM**; Grok/tools handle clarification.
- If there is **no match** but the text looks like **booking confirmation** (`_is_booking_confirmation_intent`: time hint + words like “book” / “that works”), fast path may call **`create_appointment`** with **`date_text`** only (LLM path still available if templates fail).

After **successful** `create_appointment`, offered slots are **cleared** in memory.

## LLM fallback

If a fast tool path runs but **no deterministic template** applies (`_template_from_tool_result` returns None), the pipeline logs **`llm_fallback_used`** and continues with **`chat_with_tools`** for that turn.

## Dispatch contract (logging)

Every path that runs **`commit_enqueued`** must end in one of:

| Log | Meaning |
|-----|---------|
| **`dispatch_started`** | `path=immediate` \| `path=debounce` \| `path=process` \| `path=queued_flush` |
| **`dispatch_cancelled`** | New speech, or debounce task cancelled before run |
| **`dispatch_skipped`** | `guard_reject`, `low_confidence`, or queued while busy (`queued_for_after_processing`, `queued_after_debounce`) |

**`process_user_input`** always logs **`dispatch_started path=process`** at entry; inside, **`dispatch_skipped reason=guard_reject`** or **`low_confidence`** may run before any TTS. There are **no** “committed then forgotten” paths without one of the above tags.

## Related diagnostics

- **`[TURN_GUARD]`** — commit/dispatch lifecycle.
- **`[CALL_DIAG]`** — slot selection, fast path, tool calls.
- **`[BOOKING_LATENCY]`** — timing markers.
