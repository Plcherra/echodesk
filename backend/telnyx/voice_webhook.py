"""Telnyx voice webhook: answer call and start streaming."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from urllib.parse import quote
from typing import Any

import httpx

from config import settings
from prompts.fetch import set_prompt, _build_from_supabase_sync
from quota import check_inbound_quota
from supabase_client import create_service_role_client
from telnyx.payload_utils import extract_call_control_id, extract_call_party_numbers
from telnyx.receptionist_lookup import get_receptionist_by_did_or_match
from telnyx.webhook import validate_telnyx_webhook

logger = logging.getLogger(__name__)
TELNYX_API = "https://api.telnyx.com/v2"

# Pending stream URLs: call_control_id -> stream_url (for call.answered)
# Streaming is deferred until call.answered to avoid 90034 "Call not answered yet"
_pending_streams: dict[str, str] = {}
_MAX_PENDING_STREAMS = 1000


def _set_pending_stream(call_control_id: str, stream_url: str) -> None:
    """Best-effort in-memory store for deferred streaming_start."""
    if not call_control_id:
        return
    if len(_pending_streams) >= _MAX_PENDING_STREAMS:
        # Avoid unbounded growth in multi-call scenarios. This is best-effort only.
        try:
            oldest_key = next(iter(_pending_streams.keys()))
            _pending_streams.pop(oldest_key, None)
            logger.warning(
                "[CALL_DIAG] pending_streams_evicted oldest_call_control_id=%s size=%s",
                oldest_key,
                len(_pending_streams),
            )
        except Exception:
            _pending_streams.clear()
            logger.warning("[CALL_DIAG] pending_streams_cleared size_limit=%s", _MAX_PENDING_STREAMS)
    _pending_streams[call_control_id] = stream_url


def _pop_pending_stream(call_control_id: str) -> str | None:
    if not call_control_id:
        return None
    return _pending_streams.pop(call_control_id, None)


async def _send_incoming_call_push(
    user_id: str,
    call_control_id: str,
    caller: str,
    receptionist_id: str,
    receptionist_name: str,
) -> None:
    """Send FCM push for incoming call via backend firebase-admin."""
    try:
        from push import send_incoming_call_push
        sent = await asyncio.to_thread(
            send_incoming_call_push,
            user_id=user_id,
            call_sid=call_control_id,
            caller=caller,
            receptionist_id=receptionist_id or "",
            receptionist_name=receptionist_name,
        )
        if sent == 0 and not (settings.firebase_service_account_key or "").strip():
            logger.warning("Call push skipped: FIREBASE_SERVICE_ACCOUNT_KEY not set")
    except Exception as e:
        logger.warning("FCM push failed: %s", e)


async def _send_streaming_start(call_control_id: str, stream_url: str) -> bool:
    """Send streaming_start. Returns True on success. Retries on 90034 with backoff."""
    api_key = settings.telnyx_api_key
    if not api_key:
        return False
    max_retries = 5
    delay_ms = 300
    async with httpx.AsyncClient(timeout=15.0) as client:
        for attempt in range(max_retries):
            resp = await client.post(
                f"{TELNYX_API}/calls/{call_control_id}/actions/streaming_start",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "stream_url": stream_url,
                    "stream_bidirectional_mode": "rtp",
                },
            )
            if resp.is_success:
                logger.info("Stream started for %s", call_control_id)
                return True
            try:
                err_body = resp.json()
                errors = err_body.get("errors") or []
                code = (errors[0].get("code") if errors else None) or ""
                if code == "90034" and attempt < max_retries - 1:
                    await asyncio.sleep(delay_ms / 1000.0)
                    delay_ms = min(int(delay_ms * 1.5), 2000)
                    continue
            except Exception:
                pass
            logger.error("Stream start failed: %s", resp.text)
            return False
    return False


async def _send_recording_start(call_control_id: str) -> bool:
    """Best-effort recording_start on answered calls so call.recording.saved can be emitted."""
    api_key = settings.telnyx_api_key
    if not api_key:
        return False
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                f"{TELNYX_API}/calls/{call_control_id}/actions/record_start",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "format": "mp3",
                    "channels": "single",
                    "play_beep": False,
                },
            )
        if resp.is_success:
            logger.info("[CALL_DIAG] recording_start sent call_control_id=%s", call_control_id)
            return True
        logger.warning(
            "[CALL_DIAG] recording_start failed call_control_id=%s status=%s body=%s",
            call_control_id,
            resp.status_code,
            (resp.text or "")[:240],
        )
    except Exception as e:
        logger.warning("[CALL_DIAG] recording_start exception call_control_id=%s: %s", call_control_id, e)
    return False


def _insert_call_log(
    supabase,
    call_control_id: str,
    receptionist_id: str,
    user_id: str,
    from_number: str,
    to_number: str,
    direction: str,
) -> str | None:
    """Insert call_logs row on call.initiated. Returns inserted row id or None."""
    insert_payload = {
        "call_control_id": call_control_id,
        "receptionist_id": receptionist_id,
        "user_id": user_id,
        "from_number": from_number or None,
        "to_number": to_number or None,
        "direction": direction,
        "status": "initiated",
    }
    logger.info("[CALL_DIAG] call_logs insert attempt payload call_control_id=%s receptionist_id=%s", call_control_id, receptionist_id)
    try:
        result = supabase.table("call_logs").insert(insert_payload).execute()
        inserted_id = None
        row_count = 0
        if result.data and len(result.data) > 0:
            inserted_id = result.data[0].get("id")
            row_count = len(result.data)
        logger.info(
            "[CALL_DIAG] call_logs inserted id=%s call_control_id=%s rows_returned=%s",
            inserted_id, call_control_id, row_count,
        )
        return inserted_id
    except Exception as e:
        logger.warning("[CALL_DIAG] call_logs insert failed call_control_id=%s: %s", call_control_id, e)
        return None


def _update_call_log(supabase, call_control_id: str, updates: dict) -> None:
    """Update call_logs row by call_control_id."""
    try:
        result = supabase.table("call_logs").update(updates).eq("call_control_id", call_control_id).execute()
        count = len(result.data) if result and result.data else 0
        if count == 0:
            logger.warning("[CALL_DIAG] call_logs update matched 0 rows call_control_id=%s", call_control_id)
        else:
            logger.info("[CALL_DIAG] call_logs updated call_control_id=%s rows=%s", call_control_id, count)
    except Exception as e:
        logger.warning("call_logs update failed call_control_id=%s: %s", call_control_id, e)


async def handle_voice_webhook(body: dict[str, Any], raw_body: bytes, headers: dict[str, str] | None = None) -> dict[str, Any]:
    """
    Handle Telnyx voice webhooks: call.initiated (answer + defer streaming),
    call.answered (send streaming_start), streaming.started (update call_logs),
    call.hangup / call.call-ended (forward to CDR for call history).
    Returns dict for JSON response.
    """
    event_type = (body.get("data") or {}).get("event_type") or body.get("event_type")
    data = body.get("data") or {}
    payload = data.get("payload") or data
    call_control_id = extract_call_control_id(data, payload)
    call_session_id = payload.get("call_session_id")
    call_leg_id = payload.get("call_leg_id")

    # [CALL_DIAG] Canonical call_control_id (unified with CDR for insert/finalize match)
    logger.info(
        "[CALL_DIAG] voice_webhook received event_type=%s call_control_id=%s call_session_id=%s call_leg_id=%s",
        event_type, call_control_id, call_session_id, call_leg_id,
    )

    supabase = create_service_role_client()

    # Telnyx can deliver CDR-domain events to the voice webhook URL depending on connection config.
    # Forward those events so cost/finalization/recording updates are not dropped.
    if event_type in ("call.hangup", "call.call-ended", "call.cost", "call.recording.saved"):
        logger.info("[CALL_DIAG] Forwarding %s to CDR handler", event_type)
        from telnyx.cdr_webhook import handle_cdr_webhook
        return await handle_cdr_webhook(raw_body, headers or {})

    # call.answered: send streaming_start (deferred from call.initiated), update call_logs
    if event_type == "call.answered" and call_control_id:
        _update_call_log(supabase, call_control_id, {"status": "answered", "answered_at": datetime.now(timezone.utc).isoformat()})
        stream_url = _pop_pending_stream(call_control_id)
        if stream_url:
            await _send_streaming_start(call_control_id, stream_url)
        if settings.telnyx_enable_recording:
            await _send_recording_start(call_control_id)
        return {"success": True}

    # streaming.started: update call_logs
    if event_type == "streaming.started" and call_control_id:
        _update_call_log(supabase, call_control_id, {"status": "streaming", "streaming_started_at": datetime.now(timezone.utc).isoformat()})
        return {"success": True}

    if event_type != "call.initiated" or not call_control_id:
        return {"success": True}

    parties = extract_call_party_numbers(payload)
    from_number = parties["from_number"]
    to_number = parties["to_number"]
    direction = parties["direction"]
    our_did = parties["our_did"]
    caller_number = parties["caller_number"]
    raw_direction = parties["raw_direction"]

    logger.info(
        "[CALL_DIAG] call.initiated raw from=%r to=%r raw_direction=%r -> direction=%s our_did=%r caller_number=%r",
        from_number, to_number, raw_direction, direction, our_did, caller_number,
    )

    receptionist, our_did, caller_number = get_receptionist_by_did_or_match(
        supabase, from_number, to_number, direction
    )

    # Fallback to first active receptionist is disabled by default (masks bad DID config).
    if not receptionist and settings.telnyx_allow_receptionist_fallback:
        fallback = supabase.table("receptionists").select("id, name, user_id").eq("status", "active").limit(1).execute()
        if fallback.data and len(fallback.data) > 0:
            receptionist = fallback.data[0]
            logger.warning(
                "[CALL_DIAG] DANGEROUS FALLBACK: no match for DID %s, using first active receptionist %s (TELNYX_ALLOW_RECEPTIONIST_FALLBACK=1)",
                our_did, receptionist.get("id"),
            )

    receptionist_id = receptionist.get("id", "") if receptionist else ""
    user_id = receptionist.get("user_id") if receptionist else None
    receptionist_name = receptionist.get("name", "Receptionist") if receptionist else "Receptionist"

    # Inbound call with no matching receptionist: reject (do not answer wrong line)
    if not receptionist and direction == "inbound":
        logger.warning(
            "[CALL_DIAG] Rejecting inbound call: our_did=%r (business DID) not matched to any receptionist. "
            "Ensure telnyx_phone_number or inbound_phone_number matches the assigned DID. "
            "TELNYX_ALLOW_RECEPTIONIST_FALLBACK is %s (keep False for verification).",
            our_did, "enabled" if settings.telnyx_allow_receptionist_fallback else "disabled",
        )
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                await client.post(
                    f"{TELNYX_API}/calls/{call_control_id}/actions/reject",
                    headers={
                        "Authorization": f"Bearer {settings.telnyx_api_key}",
                        "Content-Type": "application/json",
                    },
                    json={},
                )
        except Exception as e:
            logger.warning("Reject call failed: %s", e)
        return {"success": True}

    # call_logs: insert on call.initiated (every call counts, even short/rejected)
    if receptionist_id and user_id:
        inserted_id = _insert_call_log(
            supabase, call_control_id, receptionist_id, str(user_id),
            from_number, to_number, direction,
        )
        logger.info(
            "[CALL_DIAG] call.initiated processed call_control_id=%s call_logs_insert_id=%s direction=%s our_did=%r caller=%r",
            call_control_id, inserted_id, direction, our_did, caller_number,
        )
    else:
        logger.warning(
            "[CALL_DIAG] call_logs insert SKIPPED call_control_id=%s (receptionist_id=%s user_id=%s)",
            call_control_id, receptionist_id or "(empty)", user_id or "(null)",
        )

    # Check inbound quota for fixed-plan users before answering
    if user_id:
        try:
            result = check_inbound_quota(supabase, user_id)
            if not result.get("allowed"):
                logger.warning("Inbound quota exceeded for user %s, rejecting call", user_id)
                _update_call_log(supabase, call_control_id, {"status": "rejected"})
                async with httpx.AsyncClient(timeout=5.0) as client:
                    await client.post(
                        f"{TELNYX_API}/calls/{call_control_id}/actions/reject",
                        headers={"Authorization": f"Bearer {settings.telnyx_api_key}", "Content-Type": "application/json"},
                        json={},
                    )
                return {"success": True}
        except Exception as e:
            logger.warning("Inbound quota check failed: %s, allowing call", e)

    # Send FCM push to user's mobile devices (fire-and-forget)
    if user_id:
        asyncio.create_task(
            _send_incoming_call_push(
                user_id=user_id,
                call_control_id=call_control_id,
                caller=caller_number,
                receptionist_id=receptionist_id,
                receptionist_name=receptionist_name,
            )
        )

    # Pre-fetch and cache prompt, greeting, voice_id (precedence applied in fetch)
    try:
        prompt, greeting, voice_id, voice_preset_key, greeting_source, assistant_identity = _build_from_supabase_sync(
            receptionist_id,
            supabase,
        )
        set_prompt(
            call_control_id,
            prompt,
            greeting,
            voice_id,
            voice_preset_key,
            greeting_source,
            assistant_identity,
        )
        logger.info("Prompt cached for call %s (voice_id=%s)", call_control_id, "custom" if voice_id else "env_default")
    except Exception as e:
        logger.warning("Prompt pre-fetch failed: %s", e)

    api_key = settings.telnyx_api_key
    if not api_key:
        logger.error("TELNYX_API_KEY not set")
        from fastapi import HTTPException
        raise HTTPException(status_code=503, detail="Server misconfiguration")

    ws_base = settings.get_telnyx_ws_base()
    caller_phone_encoded = quote(caller_number or "", safe="")  # encode + as %2B so it survives query parsing
    params = f"call_sid={call_control_id}&direction={direction}&caller_phone={caller_phone_encoded}"
    if receptionist_id:
        params += f"&receptionist_id={receptionist_id}"
    stream_url = f"{ws_base}/api/voice/stream?{params}"
    logger.info("Stream URL for %s: %s", call_control_id, stream_url)

    async with httpx.AsyncClient(timeout=10.0) as client:
        answer_resp = await client.post(
            f"{TELNYX_API}/calls/{call_control_id}/actions/answer",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={},
        )
        if answer_resp.is_success:
            logger.info("Answered call %s", call_control_id)
            _set_pending_stream(call_control_id, stream_url)
        else:
            logger.error("Answer failed: %s", answer_resp.text)
            _update_call_log(supabase, call_control_id, {"status": "failed"})
            from fastapi import HTTPException
            raise HTTPException(
                status_code=503,
                detail=f"answer_failed: {answer_resp.text[:300]}",
            )

    return {"success": True}
