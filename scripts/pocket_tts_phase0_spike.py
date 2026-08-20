#!/usr/bin/env python3
"""Phase 0 Pocket TTS spike: latency, clone→safetensors, μ-law/MP3, concurrency.

Run on the VPS inside the pocket-tts venv. Not used by production EchoDesk.
"""

from __future__ import annotations

import argparse
import audioop
import io
import json
import statistics
import subprocess
import sys
import time
import wave
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

SAMPLE_TEXT = "Hello, thanks for calling. How can I help you today?"
STRESS_TEXT = "Hi, this is the receptionist. I can check availability and book that for you."
PHONE_LIKE_TEXT = (
    "Thanks for calling. I can check the calendar and get you booked. "
    "What day and time work best?"
)


def _pcm16_from_float(audio: np.ndarray) -> np.ndarray:
    x = np.asarray(audio, dtype=np.float32).reshape(-1)
    peak = float(np.max(np.abs(x))) if x.size else 0.0
    if peak > 1.0:
        x = x / peak
    return np.clip(x * 32767.0, -32768, 32767).astype(np.int16)


def wav_bytes(pcm16: np.ndarray, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm16.tobytes())
    return buf.getvalue()


def to_mulaw_8k(pcm16: np.ndarray, src_rate: int) -> bytes:
    if src_rate != 8000:
        gcd = np.gcd(src_rate, 8000)
        up = 8000 // gcd
        down = src_rate // gcd
        resampled = signal.resample_poly(pcm16.astype(np.float32), up, down)
        pcm16 = _pcm16_from_float(resampled / 32767.0)
    return audioop.lin2ulaw(pcm16.tobytes(), 2)


def write_mp3(ffmpeg: str, wav_path: Path, mp3_path: Path) -> None:
    subprocess.run(
        [ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-i", str(wav_path), "-codec:a", "libmp3lame", "-qscale:a", "4", str(mp3_path)],
        check=True,
    )


def first_chunk_ms(model, voice_state, text: str) -> tuple[float, float, int]:
    t0 = time.perf_counter()
    first_ms = None
    chunks = 0
    samples = 0
    for chunk in model.generate_audio_stream(voice_state, text):
        if first_ms is None:
            first_ms = (time.perf_counter() - t0) * 1000
        chunks += 1
        samples += int(chunk.numel())
    total_ms = (time.perf_counter() - t0) * 1000
    return first_ms or total_ms, total_ms, samples


def audio_to_numpy(audio) -> np.ndarray:
    arr = audio.detach().cpu().numpy()
    return np.asarray(arr, dtype=np.float32).reshape(-1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="/home/rex/pocket-tts-spike/out")
    parser.add_argument("--voices-dir", default="/home/rex/pocket-tts-spike/voices")
    parser.add_argument("--ffmpeg", default="/home/rex/pocket-tts-spike/bin/ffmpeg")
    parser.add_argument("--clone-wav", default="")
    parser.add_argument("--quantize", action="store_true")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    voices_dir = Path(args.voices_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    voices_dir.mkdir(parents=True, exist_ok=True)

    from pocket_tts import TTSModel, export_model_state

    report: dict = {"quantize": args.quantize, "steps": []}

    print("=== load_model ===", flush=True)
    t0 = time.perf_counter()
    model = TTSModel.load_model(quantize=args.quantize)
    load_ms = (time.perf_counter() - t0) * 1000
    report["load_model_ms"] = round(load_ms, 1)
    report["sample_rate"] = model.sample_rate
    report["has_voice_cloning"] = bool(getattr(model, "has_voice_cloning", False))
    print(f"load_model_ms={load_ms:.0f} sr={model.sample_rate} cloning={report['has_voice_cloning']}", flush=True)

    print("=== warm builtin voice (alba) ===", flush=True)
    t0 = time.perf_counter()
    alba = model.get_state_for_audio_prompt("alba")
    report["alba_state_ms"] = round((time.perf_counter() - t0) * 1000, 1)

    warm_first = []
    warm_total = []
    for i in range(5):
        first_ms, total_ms, samples = first_chunk_ms(model, alba, SAMPLE_TEXT)
        warm_first.append(first_ms)
        warm_total.append(total_ms)
        print(f"warm[{i}] first_chunk_ms={first_ms:.0f} total_ms={total_ms:.0f} samples={samples}", flush=True)
    report["warm_first_chunk_ms"] = {
        "n": 5,
        "min": round(min(warm_first), 1),
        "median": round(statistics.median(warm_first), 1),
        "mean": round(statistics.mean(warm_first), 1),
        "max": round(max(warm_first), 1),
    }
    report["warm_total_ms"] = {
        "min": round(min(warm_total), 1),
        "median": round(statistics.median(warm_total), 1),
        "mean": round(statistics.mean(warm_total), 1),
        "max": round(max(warm_total), 1),
    }

    print("=== export alba state to safetensors + reload ===", flush=True)
    alba_st = voices_dir / "alba.safetensors"
    t0 = time.perf_counter()
    export_model_state(alba, str(alba_st))
    report["export_alba_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    t0 = time.perf_counter()
    alba_reloaded = model.get_state_for_audio_prompt(str(alba_st))
    report["reload_alba_safetensors_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    print(f"export_alba_ms={report['export_alba_ms']} reload_ms={report['reload_alba_safetensors_ms']}", flush=True)

    clone_state = alba_reloaded
    report["clone_source"] = "alba_safetensors"
    clone_wav = Path(args.clone_wav) if args.clone_wav else None
    if clone_wav and clone_wav.exists():
        print(f"=== clone wav {clone_wav} ===", flush=True)
        try:
            t0 = time.perf_counter()
            cloned = model.get_state_for_audio_prompt(str(clone_wav), truncate=True)
            encode_ms = (time.perf_counter() - t0) * 1000
            clone_st = voices_dir / "spike_clone.safetensors"
            t0 = time.perf_counter()
            export_model_state(cloned, str(clone_st))
            export_ms = (time.perf_counter() - t0) * 1000
            t0 = time.perf_counter()
            clone_state = model.get_state_for_audio_prompt(str(clone_st))
            reload_ms = (time.perf_counter() - t0) * 1000
            report["clone_wav"] = {
                "path": str(clone_wav),
                "encode_ms": round(encode_ms, 1),
                "export_ms": round(export_ms, 1),
                "reload_safetensors_ms": round(reload_ms, 1),
                "ok": True,
            }
            report["clone_source"] = "custom_wav_safetensors"
            print(f"clone encode_ms={encode_ms:.0f} export_ms={export_ms:.0f} reload_ms={reload_ms:.0f}", flush=True)
        except Exception as err:
            report["clone_wav"] = {"path": str(clone_wav), "ok": False, "error": str(err)}
            print(f"CLONE FAILED: {err}", flush=True)

    print("=== synth + convert μ-law 8k + MP3 ===", flush=True)
    t0 = time.perf_counter()
    audio = model.generate_audio(clone_state, PHONE_LIKE_TEXT)
    synth_ms = (time.perf_counter() - t0) * 1000
    pcm = audio_to_numpy(audio)
    pcm16 = _pcm16_from_float(pcm)
    wav_path = out_dir / "preview_24k.wav"
    wav_path.write_bytes(wav_bytes(pcm16, model.sample_rate))
    t0 = time.perf_counter()
    mulaw = to_mulaw_8k(pcm16, model.sample_rate)
    mulaw_ms = (time.perf_counter() - t0) * 1000
    mulaw_path = out_dir / "preview_8k.ulaw"
    mulaw_path.write_bytes(mulaw)
    # Reconstruct 8k WAV from μ-law so we can listen to the phone path.
    pcm8k = np.frombuffer(audioop.ulaw2lin(mulaw, 2), dtype=np.int16)
    phone_wav = out_dir / "preview_phone_8k.wav"
    phone_wav.write_bytes(wav_bytes(pcm8k, 8000))
    mp3_path = out_dir / "preview.mp3"
    ffmpeg = Path(args.ffmpeg)
    if ffmpeg.exists():
        write_mp3(str(ffmpeg), wav_path, mp3_path)
        report["mp3_bytes"] = mp3_path.stat().st_size
    report["synth_phone_text_ms"] = round(synth_ms, 1)
    report["mulaw_convert_ms"] = round(mulaw_ms, 1)
    report["wav_24k_bytes"] = wav_path.stat().st_size
    report["mulaw_8k_bytes"] = len(mulaw)
    report["phone_wav_bytes"] = phone_wav.stat().st_size
    duration_s = len(pcm) / float(model.sample_rate)
    report["audio_duration_s"] = round(duration_s, 3)
    report["rtf"] = round((synth_ms / 1000.0) / duration_s, 3) if duration_s else None
    print(
        f"synth_ms={synth_ms:.0f} duration_s={duration_s:.2f} rtf={report['rtf']} "
        f"mulaw_bytes={len(mulaw)} mulaw_convert_ms={mulaw_ms:.1f}",
        flush=True,
    )

    print("=== concurrency (single model, serialized lock — thread-unsafe API) ===", flush=True)
    import threading

    lock = threading.Lock()

    def locked_synth(n: int) -> float:
        t_start = time.perf_counter()
        with lock:
            model.generate_audio(clone_state, STRESS_TEXT)
        return (time.perf_counter() - t_start) * 1000

    concurrency = {}
    for workers in (1, 2, 4):
        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(locked_synth, i) for i in range(workers)]
            waits = [f.result() for f in as_completed(futures)]
        wall_ms = (time.perf_counter() - t0) * 1000
        concurrency[str(workers)] = {
            "workers": workers,
            "wall_ms": round(wall_ms, 1),
            "per_request_wait_ms": [round(x, 1) for x in waits],
            "max_wait_ms": round(max(waits), 1),
        }
        print(f"locked_conc={workers} wall_ms={wall_ms:.0f} max_wait_ms={max(waits):.0f}", flush=True)
    report["concurrency_locked_single_model"] = concurrency

    go = report["warm_first_chunk_ms"]["median"] < 400
    report["go_no_go"] = {
        "warm_first_chunk_under_400ms": go,
        "median_first_chunk_ms": report["warm_first_chunk_ms"]["median"],
        "recommended_concurrency_cap": 2,
        "reason": (
            "Pocket generate_audio is not thread-safe; cap concurrent synths at 2 on the "
            "shared 12 vCPU box so Clarity Rex + EchoDesk keep headroom. First-chunk "
            f"{'PASS' if go else 'FAIL'} vs 400ms budget."
        ),
    }

    report_path = out_dir / "phase0_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"Wrote {report_path}", flush=True)
    return 0 if go else 2


if __name__ == "__main__":
    sys.exit(main())
