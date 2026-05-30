"""Lightweight per-call tracing for voice quality measurement.

The trace layer is intentionally passive: it records timing events and emits
structured JSON logs, but it must not affect voice control flow.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger(__name__)

_MAX_ACTIVE_TRACES = 1000
_active_traces: dict[str, "VoiceTrace"] = {}
_lock = threading.RLock()


def _json_safe(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(k): _json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_safe(v) for v in value]
    return str(value)


def _compact_attrs(attrs: dict[str, Any]) -> dict[str, Any]:
    return {str(k): _json_safe(v) for k, v in attrs.items() if v is not None}


@dataclass
class TraceEvent:
    name: str
    elapsed_ms: int
    attrs: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        data = {"name": self.name, "elapsed_ms": self.elapsed_ms}
        if self.attrs:
            data["attrs"] = self.attrs
        return data


@dataclass
class VoiceTrace:
    call_control_id: str
    started_perf: float = field(default_factory=time.perf_counter)
    started_wall: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    events: list[TraceEvent] = field(default_factory=list)
    finished: bool = False

    def mark(self, name: str, **attrs: Any) -> TraceEvent:
        elapsed_ms = int((time.perf_counter() - self.started_perf) * 1000)
        event = TraceEvent(name=name, elapsed_ms=elapsed_ms, attrs=_compact_attrs(attrs))
        self.events.append(event)
        payload = {
            "call_control_id": self.call_control_id,
            "event": event.as_dict(),
        }
        logger.info("[VOICE_TRACE] event %s", json.dumps(payload, sort_keys=True, separators=(",", ":")))
        return event

    def summary(self, *, reason: str = "finished", **attrs: Any) -> dict[str, Any]:
        events = [e.as_dict() for e in self.events]
        firsts: dict[str, int] = {}
        for e in self.events:
            firsts.setdefault(e.name, e.elapsed_ms)

        durations: dict[str, int] = {}

        def span(name: str, start: str, end: str) -> None:
            if start in firsts and end in firsts:
                durations[name] = max(0, firsts[end] - firsts[start])

        span("webhook_to_answer_accepted_ms", "webhook_received", "answer_accepted")
        span("answer_request_to_accepted_ms", "answer_request_sent", "answer_accepted")
        span("answer_accepted_to_streaming_start_sent_ms", "answer_accepted", "streaming_start_sent")
        span("websocket_to_deepgram_connected_ms", "websocket_accepted", "deepgram_connected")
        span("websocket_to_first_inbound_audio_ms", "websocket_accepted", "first_inbound_audio")
        span("webhook_to_first_assistant_audio_ms", "webhook_received", "assistant_audio_start")
        span("first_inbound_audio_to_first_final_transcript_ms", "first_inbound_audio", "first_final_transcript")

        turn_summaries = _build_turn_summaries(self.events)
        if turn_summaries:
            first_turn = next((t for t in turn_summaries if t.get("commit_to_first_audio_ms") is not None), None)
            if first_turn and first_turn.get("commit_to_first_audio_ms") is not None:
                durations["first_turn_commit_to_first_audio_ms"] = int(first_turn["commit_to_first_audio_ms"])

        if self.events:
            durations["trace_total_ms"] = max(0, self.events[-1].elapsed_ms - self.events[0].elapsed_ms)

        return {
            "call_control_id": self.call_control_id,
            "started_at": self.started_wall,
            "reason": reason,
            "event_count": len(self.events),
            "durations_ms": durations,
            "turns": turn_summaries,
            "attrs": _compact_attrs(attrs),
            "events": events,
        }


def _build_turn_summaries(events: list[TraceEvent]) -> list[dict[str, Any]]:
    by_commit: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for e in events:
        cid = e.attrs.get("commit_id")
        if cid is None:
            continue
        key = str(cid)
        if key not in by_commit:
            by_commit[key] = {"commit_id": cid}
            order.append(key)
        rec = by_commit[key]
        if e.name == "commit_enqueued":
            rec["commit_enqueued_ms"] = e.elapsed_ms
            if "reason" in e.attrs:
                rec["reason"] = e.attrs["reason"]
            if "trigger_source" in e.attrs:
                rec["trigger_source"] = e.attrs["trigger_source"]
        elif e.name == "dispatch_started":
            rec.setdefault("dispatch_started_ms", e.elapsed_ms)
            if "path" in e.attrs:
                rec.setdefault("dispatch_path", e.attrs["path"])
        elif e.name == "assistant_audio_start":
            rec.setdefault("first_assistant_audio_ms", e.elapsed_ms)
            if "label" in e.attrs:
                rec.setdefault("first_audio_label", e.attrs["label"])
        elif e.name == "grok_request_sent":
            rec.setdefault("grok_request_ms", e.elapsed_ms)
        elif e.name == "grok_response_received":
            rec.setdefault("grok_response_ms", e.elapsed_ms)
        elif e.name == "calendar_tool_request":
            rec.setdefault("calendar_tool_request_ms", e.elapsed_ms)
        elif e.name == "calendar_tool_response":
            rec.setdefault("calendar_tool_response_ms", e.elapsed_ms)

    out: list[dict[str, Any]] = []
    for key in order:
        rec = by_commit[key]
        if "commit_enqueued_ms" in rec and "first_assistant_audio_ms" in rec:
            rec["commit_to_first_audio_ms"] = max(0, rec["first_assistant_audio_ms"] - rec["commit_enqueued_ms"])
        if "grok_request_ms" in rec and "grok_response_ms" in rec:
            rec["grok_ms"] = max(0, rec["grok_response_ms"] - rec["grok_request_ms"])
        if "calendar_tool_request_ms" in rec and "calendar_tool_response_ms" in rec:
            rec["calendar_tool_ms"] = max(0, rec["calendar_tool_response_ms"] - rec["calendar_tool_request_ms"])
        out.append(rec)
    return out


def get_voice_trace(call_control_id: str | None, *, create: bool = True) -> VoiceTrace | None:
    ccid = (call_control_id or "").strip()
    if not ccid:
        return None
    with _lock:
        trace = _active_traces.get(ccid)
        if trace or not create:
            return trace
        if len(_active_traces) >= _MAX_ACTIVE_TRACES:
            try:
                oldest = next(iter(_active_traces))
                evicted = _active_traces.pop(oldest)
                logger.warning(
                    "[VOICE_TRACE] evicted %s",
                    json.dumps(evicted.summary(reason="evicted"), sort_keys=True, separators=(",", ":")),
                )
            except Exception:
                _active_traces.clear()
        trace = VoiceTrace(call_control_id=ccid)
        _active_traces[ccid] = trace
        return trace


def mark_voice_event(call_control_id: str | None, name: str, **attrs: Any) -> None:
    trace = get_voice_trace(call_control_id)
    if not trace:
        return
    with _lock:
        trace.mark(name, **attrs)


def finish_voice_trace(call_control_id: str | None, *, reason: str = "finished", **attrs: Any) -> dict[str, Any] | None:
    ccid = (call_control_id or "").strip()
    if not ccid:
        return None
    with _lock:
        trace = _active_traces.pop(ccid, None)
        if not trace:
            return None
        if not trace.finished:
            trace.mark("trace_finished", reason=reason)
            trace.finished = True
        summary = trace.summary(reason=reason, **attrs)
    logger.info("[VOICE_TRACE] summary %s", json.dumps(summary, sort_keys=True, separators=(",", ":")))
    return summary


def reset_voice_traces_for_tests() -> None:
    with _lock:
        _active_traces.clear()
