#!/usr/bin/env python3
"""Localhost Pocket TTS sidecar for EchoDesk voice clones.

Binds 127.0.0.1 only. Official `pocket-tts serve` cannot load local
`.safetensors` paths, so this thin wrapper keeps the model warm and
exposes export + μ-law/MP3 synth for EchoDesk.
"""

from __future__ import annotations

import audioop
import io
import logging
import os
import subprocess
import threading
import time
import wave
from pathlib import Path

import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field
from scipy import signal

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("pocket-tts-sidecar")

HOST = os.environ.get("POCKET_TTS_HOST", "127.0.0.1")
PORT = int(os.environ.get("POCKET_TTS_PORT", "8100"))
VOICES_DIR = Path(os.environ.get("POCKET_TTS_VOICES_DIR", "/opt/echodesk/voices")).resolve()
FFMPEG = os.environ.get("POCKET_TTS_FFMPEG", "/opt/echodesk/pocket-tts/bin/ffmpeg")
CONCURRENCY = max(1, int(os.environ.get("POCKET_TTS_CONCURRENCY", "2")))
QUANTIZE = os.environ.get("POCKET_TTS_QUANTIZE", "").strip().lower() in {"1", "true", "yes"}

_model = None
_synth_lock = threading.Lock()
_slots = threading.BoundedSemaphore(CONCURRENCY)


def _pcm16_from_float(audio: np.ndarray) -> np.ndarray:
    x = np.asarray(audio, dtype=np.float32).reshape(-1)
    peak = float(np.max(np.abs(x))) if x.size else 0.0
    if peak > 1.0:
        x = x / peak
    return np.clip(x * 32767.0, -32768, 32767).astype(np.int16)


def _wav_bytes(pcm16: np.ndarray, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm16.tobytes())
    return buf.getvalue()


def _to_mulaw_8k(pcm16: np.ndarray, src_rate: int) -> bytes:
    if src_rate != 8000:
        gcd = np.gcd(src_rate, 8000)
        up = 8000 // gcd
        down = src_rate // gcd
        resampled = signal.resample_poly(pcm16.astype(np.float32), up, down)
        pcm16 = _pcm16_from_float(resampled / 32767.0)
    return audioop.lin2ulaw(pcm16.tobytes(), 2)


def _decode_to_wav(src: Path, dest: Path, *, sample_rate: int) -> Path:
    """Normalize any phone upload (m4a/aac/mp3/wav) to mono PCM WAV for Pocket."""
    if not Path(FFMPEG).exists():
        raise HTTPException(status_code=500, detail="ffmpeg not available")
    dest.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        [
            FFMPEG,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(src),
            "-ac",
            "1",
            "-ar",
            str(max(8000, int(sample_rate))),
            "-sample_fmt",
            "s16",
            str(dest),
        ],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0 or not dest.is_file() or dest.stat().st_size < 800:
        err = (proc.stderr or b"").decode("utf-8", errors="replace")[:300]
        logger.warning("export-voice decode failed src=%s err=%s", src.name, err)
        raise HTTPException(
            status_code=400,
            detail="Could not read that recording. Try Record again, or upload a WAV/MP3.",
        )
    return dest


def _to_mp3(wav_bytes: bytes) -> bytes:
    if not Path(FFMPEG).exists():
        raise HTTPException(status_code=500, detail="ffmpeg not available for MP3")
    proc = subprocess.run(
        [FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-codec:a", "libmp3lame", "-qscale:a", "4", "-f", "mp3", "pipe:1"],
        input=wav_bytes,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout:
        raise HTTPException(status_code=500, detail="mp3 encode failed")
    return proc.stdout


def _safe_voice_path(raw: str) -> Path:
    path = Path(raw).resolve()
    try:
        path.relative_to(VOICES_DIR)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="voice_path must be under voices dir") from exc
    if not path.is_file():
        raise HTTPException(status_code=404, detail="voice embedding not found")
    return path


def get_model():
    global _model
    if _model is None:
        from pocket_tts import TTSModel

        t0 = time.perf_counter()
        _model = TTSModel.load_model(quantize=QUANTIZE)
        logger.info(
            "model_loaded ms=%.0f cloning=%s sr=%s quantize=%s",
            (time.perf_counter() - t0) * 1000,
            bool(getattr(_model, "has_voice_cloning", False)),
            _model.sample_rate,
            QUANTIZE,
        )
    return _model


app = FastAPI(title="EchoDesk Pocket TTS sidecar", docs_url=None, redoc_url=None)


@app.on_event("startup")
def _startup() -> None:
    VOICES_DIR.mkdir(parents=True, exist_ok=True)
    get_model()


@app.get("/health")
def health() -> dict:
    model = get_model()
    return {
        "status": "ok",
        "has_voice_cloning": bool(getattr(model, "has_voice_cloning", False)),
        "sample_rate": model.sample_rate,
        "concurrency_cap": CONCURRENCY,
        "voices_dir": str(VOICES_DIR),
    }


class TtsRequest(BaseModel):
    text: str
    voice_path: str
    audio_format: str = Field(default="mulaw", alias="format")

    model_config = {"populate_by_name": True}


@app.post("/tts")
def tts(body: TtsRequest) -> Response:
    text = (body.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text required")
    fmt = (body.audio_format or "mulaw").strip().lower()
    if fmt not in {"mulaw", "mp3", "wav"}:
        raise HTTPException(status_code=400, detail="format must be mulaw, mp3, or wav")
    voice_path = _safe_voice_path(body.voice_path)
    if not _slots.acquire(blocking=False):
        raise HTTPException(status_code=503, detail="pocket_tts_busy")
    t0 = time.perf_counter()
    try:
        model = get_model()
        with _synth_lock:
            state = model.get_state_for_audio_prompt(str(voice_path))
            audio = model.generate_audio(state, text)
        pcm = np.asarray(audio.detach().cpu().numpy(), dtype=np.float32).reshape(-1)
        pcm16 = _pcm16_from_float(pcm)
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        logger.info("tts format=%s chars=%s ms=%s voice=%s", fmt, len(text), elapsed_ms, voice_path.name)
        if fmt == "mulaw":
            return Response(content=_to_mulaw_8k(pcm16, model.sample_rate), media_type="audio/basic")
        wav = _wav_bytes(pcm16, model.sample_rate)
        if fmt == "wav":
            return Response(content=wav, media_type="audio/wav")
        return Response(content=_to_mp3(wav), media_type="audio/mpeg")
    except HTTPException:
        raise
    except Exception as err:
        logger.exception("tts failed: %s", err)
        raise HTTPException(status_code=502, detail="pocket_tts_failed") from err
    finally:
        _slots.release()


@app.post("/export-voice")
async def export_voice(
    audio: UploadFile = File(...),
    user_id: str = Form(...),
    clone_id: str = Form(...),
) -> JSONResponse:
    user_id = (user_id or "").strip()
    clone_id = (clone_id or "").strip()
    if not user_id or not clone_id or "/" in user_id or "/" in clone_id or ".." in user_id or ".." in clone_id:
        raise HTTPException(status_code=400, detail="invalid user_id or clone_id")
    model = get_model()
    if not getattr(model, "has_voice_cloning", False):
        raise HTTPException(
            status_code=503,
            detail=(
                "Voice cloning weights are gated. Accept https://huggingface.co/kyutai/pocket-tts "
                "and set HF_TOKEN on the sidecar, then restart."
            ),
        )
    suffix = Path(audio.filename or "sample.wav").suffix.lower() or ".wav"
    dest_dir = VOICES_DIR / user_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    raw_path = dest_dir / f"{clone_id}{suffix}"
    wav_path = dest_dir / f"{clone_id}.prompt.wav"
    dest_path = dest_dir / f"{clone_id}.safetensors"
    payload = await audio.read()
    if not payload or len(payload) > 8 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="audio must be 1 byte–8MB")
    raw_path.write_bytes(payload)
    t0 = time.perf_counter()
    try:
        from pocket_tts import export_model_state

        prompt = _decode_to_wav(raw_path, wav_path, sample_rate=int(model.sample_rate))
        state = model.get_state_for_audio_prompt(str(prompt), truncate=True)
        export_model_state(state, str(dest_path))
    except HTTPException:
        raise
    except Exception as err:
        logger.exception("export-voice failed: %s", err)
        raise HTTPException(status_code=502, detail="export_voice_failed") from err
    finally:
        raw_path.unlink(missing_ok=True)
        wav_path.unlink(missing_ok=True)
    logger.info("export-voice clone_id=%s ms=%.0f path=%s", clone_id, (time.perf_counter() - t0) * 1000, dest_path)
    return JSONResponse({"path": str(dest_path), "bytes": dest_path.stat().st_size})


@app.delete("/voices")
def delete_voice(path: str) -> dict:
    voice_path = _safe_voice_path(path)
    voice_path.unlink(missing_ok=True)
    parent = voice_path.parent
    if parent != VOICES_DIR and parent.is_dir() and not any(parent.iterdir()):
        parent.rmdir()
    return {"ok": True}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("sidecar:app", host=HOST, port=PORT, workers=1)
