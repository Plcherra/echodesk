"""HTTP client for the localhost Pocket TTS sidecar."""

from __future__ import annotations

import logging
from typing import Any

import httpx

from config import settings

logger = logging.getLogger(__name__)


class PocketTtsError(Exception):
    """Sidecar request failed."""

    def __init__(self, message: str, *, status_code: int | None = None, busy: bool = False) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.busy = busy


def pocket_enabled() -> bool:
    return bool(settings.pocket_tts_enabled) and bool((settings.pocket_tts_url or "").strip())


def _base_url() -> str:
    return (settings.pocket_tts_url or "http://127.0.0.1:8100").rstrip("/")


def _timeout() -> httpx.Timeout:
    return httpx.Timeout(settings.pocket_tts_timeout_seconds)


async def pocket_health() -> dict[str, Any] | None:
    if not pocket_enabled():
        return None
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(3.0)) as client:
            res = await client.get(f"{_base_url()}/health")
            res.raise_for_status()
            return res.json()
    except Exception as err:
        logger.warning("[TTS] pocket_health_failed error=%s", err)
        return {"status": "error", "error": str(err)}


async def synthesize(
    text: str,
    voice_path: str,
    *,
    audio_format: str = "mulaw",
) -> bytes:
    if not pocket_enabled():
        raise PocketTtsError("Pocket TTS is disabled")
    try:
        async with httpx.AsyncClient(timeout=_timeout()) as client:
            res = await client.post(
                f"{_base_url()}/tts",
                json={"text": text, "voice_path": voice_path, "format": audio_format},
            )
    except httpx.RequestError as err:
        raise PocketTtsError(f"pocket sidecar unreachable: {err}") from err
    if res.status_code == 503:
        raise PocketTtsError("pocket_tts_busy", status_code=503, busy=True)
    if res.status_code >= 400:
        raise PocketTtsError(
            f"pocket sidecar {res.status_code}: {res.text[:200]}",
            status_code=res.status_code,
        )
    return res.content


async def export_voice(*, user_id: str, clone_id: str, filename: str, audio: bytes) -> str:
    if not pocket_enabled():
        raise PocketTtsError("Pocket TTS is disabled")
    files = {"audio": (filename or "sample.wav", audio, "application/octet-stream")}
    data = {"user_id": user_id, "clone_id": clone_id}
    try:
        async with httpx.AsyncClient(timeout=_timeout()) as client:
            res = await client.post(f"{_base_url()}/export-voice", data=data, files=files)
    except httpx.RequestError as err:
        raise PocketTtsError(f"pocket sidecar unreachable: {err}") from err
    if res.status_code >= 400:
        raise PocketTtsError(
            f"export-voice {res.status_code}: {res.text[:300]}",
            status_code=res.status_code,
        )
    payload = res.json()
    path = (payload.get("path") or "").strip()
    if not path:
        raise PocketTtsError("export-voice missing path")
    return path


async def delete_voice(path: str) -> None:
    if not pocket_enabled() or not path:
        return
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(10.0)) as client:
            await client.delete(f"{_base_url()}/voices", params={"path": path})
    except Exception as err:
        logger.warning("[TTS] pocket_delete_voice_failed path=%s error=%s", path, err)
