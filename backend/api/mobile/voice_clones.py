"""Mobile API: Pocket TTS voice clones."""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse, Response

from api.auth import get_user_from_request
from config import settings
from voice.pocket_tts import PocketTtsError, delete_voice, export_voice, pocket_enabled
from voice.tts_facade import pocket_preview_mp3
from voice_presets import PREVIEW_SAMPLE_TEXT, ResolvedTtsVoice

logger = logging.getLogger(__name__)
router = APIRouter(tags=["mobile-voice-clones"])

_MAX_AUDIO_BYTES = 8 * 1024 * 1024
_ALLOWED_SUFFIXES = {".wav", ".mp3", ".m4a", ".aac", ".ogg", ".flac", ".webm"}


def _require_auth(request: Request) -> tuple[dict | None, Any]:
    user, supabase = get_user_from_request(request)
    if not user or not supabase:
        return (None, None)
    return (user, supabase)


def _serialize(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row.get("id"),
        "label": row.get("label"),
        "consent_at": row.get("consent_at"),
        "created_at": row.get("created_at"),
        "preview_path": f"/api/mobile/voice-clones/{row.get('id')}/preview",
    }


def _friendly_export_error(err: PocketTtsError) -> str:
    raw = str(err or "")
    if "Could not read that recording" in raw:
        return "Could not read that recording. Try Record again, or upload a WAV/MP3."
    if "export_voice_failed" in raw or "export-voice 502" in raw:
        return "Could not clone that recording. Try again, or record a new 5–30 second take."
    if "unreachable" in raw.lower() or "503" in raw or "gated" in raw.lower():
        return "Voice cloning is temporarily unavailable. Try again in a few minutes."
    return "Could not create voice clone. Try recording again."


def _truthy_consent(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"true", "1", "yes", "y", "on"}
    return False


def assert_owned_clone(supabase, user_id: str, clone_id: str) -> str | None:
    """Return an error message if clone_id is not owned, else None."""
    if not _owned_clone(supabase, user_id, clone_id):
        return "Voice clone not found."
    return None


def _owned_clone(supabase, user_id: str, clone_id: str) -> dict[str, Any] | None:
    res = (
        supabase.table("voice_clones")
        .select("id, user_id, label, embedding_path, consent_at, created_at")
        .eq("id", clone_id)
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    rows = res.data if res and isinstance(res.data, list) else []
    return rows[0] if rows else None


@router.post("/voice-clones")
async def create_voice_clone(
    request: Request,
    audio: UploadFile = File(...),
    consent: str = Form(...),
    label: str = Form("My voice"),
):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    if not _truthy_consent(consent):
        return JSONResponse({"error": "Consent is required to clone your voice."}, status_code=400)
    if not pocket_enabled():
        return JSONResponse({"error": "Voice cloning is not enabled on this server."}, status_code=503)

    filename = (audio.filename or "sample.wav").strip()
    suffix = ("." + filename.rsplit(".", 1)[-1].lower()) if "." in filename else ".wav"
    if suffix not in _ALLOWED_SUFFIXES:
        return JSONResponse({"error": "Upload a short WAV or MP3 sample (5–30 seconds)."}, status_code=400)

    payload = await audio.read()
    if not payload or len(payload) > _MAX_AUDIO_BYTES:
        return JSONResponse({"error": "Audio must be under 8MB."}, status_code=400)

    clone_id = str(uuid.uuid4())
    try:
        embedding_path = await export_voice(
            user_id=user["id"],
            clone_id=clone_id,
            filename=filename,
            audio=payload,
        )
    except PocketTtsError as err:
        logger.warning("[voice-clones] export failed user=%s error=%s", user["id"], err)
        return JSONResponse(
            {"error": _friendly_export_error(err)},
            status_code=err.status_code or 502,
        )

    now = datetime.now(timezone.utc).isoformat()
    row = {
        "id": clone_id,
        "user_id": user["id"],
        "label": (label or "My voice").strip() or "My voice",
        "embedding_path": embedding_path,
        "consent_at": now,
        "created_at": now,
        "updated_at": now,
    }
    try:
        inserted = supabase.table("voice_clones").insert(row).execute()
        data = (inserted.data or [row])[0] if inserted.data else row
    except Exception as err:
        logger.exception("[voice-clones] insert failed: %s", err)
        await delete_voice(embedding_path)
        return JSONResponse({"error": "Could not save voice clone."}, status_code=500)
    return _serialize(data)


@router.get("/voice-clones")
async def list_voice_clones(request: Request):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    res = (
        supabase.table("voice_clones")
        .select("id, label, consent_at, created_at")
        .eq("user_id", user["id"])
        .order("created_at", desc=True)
        .execute()
    )
    rows = res.data if res and isinstance(res.data, list) else []
    return {"clones": [_serialize(r) for r in rows]}


@router.get("/voice-clones/{clone_id}/preview")
async def preview_voice_clone(request: Request, clone_id: str):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    row = _owned_clone(supabase, user["id"], clone_id)
    if not row:
        return JSONResponse({"error": "Not found"}, status_code=404)
    voice = ResolvedTtsVoice(
        google_language_code="en-US",
        google_voice_name=settings.google_tts_default_voice_name,
        model_id=None,
        provider="pocket",
        voice_clone_id=clone_id,
        pocket_voice_path=row.get("embedding_path"),
    )
    try:
        audio = await pocket_preview_mp3(PREVIEW_SAMPLE_TEXT, voice)
        return Response(content=audio, media_type="audio/mpeg")
    except Exception as err:
        logger.warning("[voice-clones/preview] %s: %s", clone_id, err)
        return JSONResponse({"error": "Preview failed"}, status_code=502)


@router.delete("/voice-clones/{clone_id}")
async def delete_voice_clone(request: Request, clone_id: str):
    user, supabase = _require_auth(request)
    if not user:
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    row = _owned_clone(supabase, user["id"], clone_id)
    if not row:
        return JSONResponse({"error": "Not found"}, status_code=404)
    try:
        supabase.table("receptionists").update({"voice_clone_id": None}).eq("voice_clone_id", clone_id).eq(
            "user_id", user["id"]
        ).execute()
        supabase.table("voice_clones").delete().eq("id", clone_id).eq("user_id", user["id"]).execute()
    except Exception as err:
        logger.exception("[voice-clones] delete failed: %s", err)
        return JSONResponse({"error": "Could not delete voice clone."}, status_code=500)
    await delete_voice((row.get("embedding_path") or "").strip())
    return {"ok": True}
