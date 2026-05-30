from __future__ import annotations

import json
import sys
from pathlib import Path

from voice.trace import VoiceTrace, finish_voice_trace, mark_voice_event, reset_voice_traces_for_tests

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.voice_trace_report import format_markdown_report, parse_voice_trace_summaries  # noqa: E402


def test_voice_trace_builds_call_and_turn_durations():
    trace = VoiceTrace("call-123")

    trace.mark("webhook_received")
    trace.mark("answer_request_sent")
    trace.mark("answer_accepted")
    trace.mark("streaming_start_sent")
    trace.mark("websocket_accepted")
    trace.mark("deepgram_connected")
    trace.mark("first_inbound_audio")
    trace.mark("first_final_transcript")
    trace.mark("commit_enqueued", commit_id=1, reason="speech_final", trigger_source="speech_final")
    trace.mark("dispatch_started", commit_id=1, path="process")
    trace.mark("grok_request_sent", commit_id=1)
    trace.mark("grok_response_received", commit_id=1)
    trace.mark("calendar_tool_request", commit_id=1, tool="create_appointment")
    trace.mark("calendar_tool_response", commit_id=1, tool="create_appointment")
    trace.mark("assistant_audio_start", commit_id=1, label="llm_response")

    summary = trace.summary(reason="unit")

    assert summary["call_control_id"] == "call-123"
    assert summary["event_count"] == 15
    assert "webhook_to_answer_accepted_ms" in summary["durations_ms"]
    assert "websocket_to_deepgram_connected_ms" in summary["durations_ms"]
    assert summary["turns"][0]["commit_id"] == 1
    assert "commit_to_first_audio_ms" in summary["turns"][0]
    assert "grok_ms" in summary["turns"][0]
    assert "calendar_tool_ms" in summary["turns"][0]
    assert summary["turns"][0]["trigger_source"] == "speech_final"


def test_global_trace_finishes_once():
    reset_voice_traces_for_tests()

    mark_voice_event("call-456", "webhook_received")
    mark_voice_event("call-456", "assistant_audio_start", label="greeting")

    summary = finish_voice_trace("call-456", reason="hangup", connected_seconds=12)

    assert summary is not None
    assert summary["reason"] == "hangup"
    assert summary["attrs"]["connected_seconds"] == 12
    assert summary["events"][-1]["name"] == "trace_finished"
    assert finish_voice_trace("call-456") is None


def test_voice_trace_report_parser_and_markdown():
    payload = {
        "call_control_id": "abc-very-long-call-id",
        "reason": "call.hangup",
        "event_count": 4,
        "durations_ms": {
            "webhook_to_first_assistant_audio_ms": 900,
            "first_inbound_audio_to_first_final_transcript_ms": 300,
        },
        "turns": [{"commit_id": 1, "commit_to_first_audio_ms": 1200, "grok_ms": 400, "calendar_tool_ms": 250}],
    }
    lines = [
        "noise",
        "[VOICE_TRACE] summary " + json.dumps(payload, separators=(",", ":")),
    ]

    summaries = parse_voice_trace_summaries(lines)
    report = format_markdown_report(summaries)

    assert summaries == [payload]
    assert "very-long-call-id"[-12:] in report
    assert "1200" in report
    assert "calendar ms" in report
