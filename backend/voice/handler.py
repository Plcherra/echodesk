"""WebSocket handler for voice stream."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
from urllib.parse import parse_qs, urlparse

from starlette.websockets import WebSocket

from config import settings
from voice.constants import (
    SILENCE_PACKET,
    SILENCE_INTERVAL_MS,
    PING_INTERVAL_MS,
    RECORDING_CONSENT_PHRASE,
    get_voice_api_key,
    get_prompt_base,
)
from supabase_client import create_service_role_client
from voice.send_media import send_media
from voice.pipeline import run_voice_pipeline
from prompts.fetch import get_cached_prompt, fetch_prompt
from voice_presets import resolve_tts_voice

logger = logging.getLogger(__name__)

# Duplicate connection prevention
active_by_call_sid: dict[str, WebSocket] = {}


def get_stream_params(query: str) -> dict[str, str]:
    """Parse query string for call_sid, receptionist_id, caller_phone, direction."""
    params = {}
    if not query:
        return params
    if query.startswith("?"):
        query = query[1:]
    parsed = parse_qs(query)
    for k in ("receptionist_id", "call_sid", "caller_phone", "direction"):
        if k in parsed and parsed[k]:
            params[k] = parsed[k][0]
    return params


def parse_message_chunk(data: str | bytes) -> bytes | None:
    """Extract base64 audio from Telnyx media message."""
    if isinstance(data, bytes):
        data = data.decode("utf-8", errors="replace")
    try:
        msg = json.loads(data)
        b64 = (msg.get("media") or {}).get("payload") or msg.get("payload")
        return base64.b64decode(b64) if b64 else None
    except (json.JSONDecodeError, TypeError):
        return None


async def handle_voice_stream_connection(ws: WebSocket) -> None:
    """Handle WebSocket connection for voice stream."""
    query = ws.scope.get("query_string", b"").decode("utf-8")
    params = get_stream_params(query)
    receptionist_id = params.get("receptionist_id", "")
    call_sid = params.get("call_sid", "")
    caller_phone = (params.get("caller_phone") or "").strip() or None

    # Duplicate check disabled temporarily - was potentially causing 403.
    # If duplicate, both run; first to send media wins. Re-enable if needed.
    if call_sid:
        active_by_call_sid[call_sid] = ws

    # Initial silence
    await send_media(ws, SILENCE_PACKET)

    # Ping + silence every 3s
    interval_sec = (SILENCE_INTERVAL_MS or 3000) / 1000.0
    ping_silence_task: asyncio.Task | None = None

    async def ping_silence_loop() -> None:
        while True:
            await asyncio.sleep(interval_sec)
            if ws.client_state.name != "CONNECTED":
                return
            try:
                await send_media(ws, SILENCE_PACKET)
                await ws.send_text(json.dumps({"event": "ping"}))
            except Exception:
                pass

    ping_silence_task = asyncio.create_task(ping_silence_loop())

    # Validate keys (Deepgram + Grok required; Google TTS validated at startup)
    if not settings.deepgram_api_key or not settings.grok_api_key:
        if ping_silence_task:
            ping_silence_task.cancel()
        if call_sid:
            active_by_call_sid.pop(call_sid, None)
        await ws.close(code=1011, reason="Server misconfiguration")
        return

    pipeline_send_audio = None
    pipeline_stop = None
    dummy_task = None

    if os.environ.get("VOICE_DUMMY_TEST") == "1":
        async def dummy_loop() -> None:
            while ws.client_state.name == "CONNECTED":
                await asyncio.sleep(2)
                try:
                    await send_media(ws, bytes([0xFF] * 8000))
                except Exception:
                    break
        dummy_task = asyncio.create_task(dummy_loop())
    else:
        try:
            prompt_data = get_cached_prompt(call_sid) if call_sid else None
            if not prompt_data:
                supabase = create_service_role_client()
                prompt_data = await fetch_prompt(receptionist_id, supabase)

            if ws.client_state.name != "CONNECTED":
                return
            if call_sid and active_by_call_sid.get(call_sid) != ws:
                return

            if len(prompt_data) >= 6:
                prompt, greeting, cached_voice_id, voice_preset_key, greeting_source, assistant_identity = prompt_data
            else:
                prompt, greeting, cached_voice_id, voice_preset_key, greeting_source = prompt_data
                assistant_identity = "Receptionist"
            resolved_tts_voice = resolve_tts_voice(voice_preset_key, cached_voice_id)
            logger.info(
                "call_voice_setup receptionist_id=%s voice_preset_key=%s google_voice=%s greeting_source=%s assistant_identity=%s",
                receptionist_id,
                voice_preset_key,
                resolved_tts_voice.google_voice_name,
                greeting_source,
                assistant_identity,
            )
            config = {
                "deepgram_api_key": settings.deepgram_api_key,
                "grok_api_key": settings.grok_api_key,
                "system_prompt": prompt,
                "greeting": greeting,
                "assistant_identity": assistant_identity,
                "tts_provider": "google",
                "resolved_tts_voice": resolved_tts_voice,
            }
            if caller_phone:
                config["caller_phone"] = caller_phone
            if call_sid:
                config["call_control_id"] = call_sid
            voice_api_key = get_voice_api_key()
            prompt_base = get_prompt_base()
            if receptionist_id and voice_api_key:
                config["receptionist_id"] = receptionist_id
                config["voice_server_api_key"] = voice_api_key
                config["voice_server_base_url"] = prompt_base.rstrip("/")
            if call_sid:
                config["consent_phrase"] = RECORDING_CONSENT_PHRASE

                async def on_consent_played() -> None:
                    try:
                        sb = create_service_role_client()
                        await asyncio.to_thread(
                            lambda: sb.table("call_logs")
                            .update({"recording_consent_played": True})
                            .eq("call_control_id", call_sid)
                            .execute()
                        )
                        logger.info(
                            "[voice/stream] call_logs.recording_consent_played set true for call_control_id=%s",
                            call_sid,
                        )
                    except Exception as e:
                        logger.warning(
                            "[voice/stream] failed to set recording_consent_played for call_control_id=%s: %s",
                            call_sid,
                            e,
                        )

                config["on_consent_played"] = on_consent_played

            async def on_audio(buf: bytes) -> None:
                if ws.client_state.name == "CONNECTED":
                    try:
                        await send_media(ws, buf)
                    except Exception:
                        pass

            pipeline_send_audio, pipeline_stop = await run_voice_pipeline(
                config,
                on_audio=on_audio,
                on_error=lambda e: logger.error("[voice/stream] Pipeline error: %s", e),
            )
        except Exception as e:
            logger.exception("Pipeline init failed: %s", e)
            if ws.client_state.name == "CONNECTED":
                await ws.close(code=1011, reason="Pipeline init error")
            return

    try:
        while True:
            msg = await ws.receive()
            data = msg.get("text") or (msg.get("bytes") and msg["bytes"].decode("utf-8", errors="replace")) or ""
            if isinstance(data, bytes):
                data = data.decode("utf-8", errors="replace")
            chunk = parse_message_chunk(data)
            if chunk and pipeline_send_audio:
                pipeline_send_audio(chunk)
    except Exception as e:
        if "disconnect" not in str(e).lower():
            logger.debug("WebSocket receive ended: %s", e)
    finally:
        if ping_silence_task and not ping_silence_task.done():
            ping_silence_task.cancel()
        if dummy_task and not dummy_task.done():
            dummy_task.cancel()
        if call_sid and active_by_call_sid.get(call_sid) == ws:
            active_by_call_sid.pop(call_sid, None)
        if pipeline_stop:
            pipeline_stop()
