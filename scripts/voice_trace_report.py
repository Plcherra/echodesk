#!/usr/bin/env python3
"""Build a compact voice latency report from backend logs.

Reads lines containing `[VOICE_TRACE] summary {...}` from files or stdin and
prints a Markdown table for Phase 1 voice-quality analysis.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Iterable, Any

SUMMARY_MARKER = "[VOICE_TRACE] summary "


def parse_voice_trace_summaries(lines: Iterable[str]) -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    for line in lines:
        if SUMMARY_MARKER not in line:
            continue
        payload = line.split(SUMMARY_MARKER, 1)[1].strip()
        try:
            parsed = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            summaries.append(parsed)
    return summaries


def _ms(summary: dict[str, Any], key: str) -> str:
    durations = summary.get("durations_ms") or {}
    value = durations.get(key)
    return "" if value is None else str(value)


def _first_turn(summary: dict[str, Any]) -> dict[str, Any]:
    turns = summary.get("turns") or []
    return turns[0] if turns and isinstance(turns[0], dict) else {}


def format_markdown_report(summaries: list[dict[str, Any]]) -> str:
    if not summaries:
        return "No `[VOICE_TRACE] summary` lines found."

    rows = [
        "| call | reason | events | webhook->audio ms | inbound->transcript ms | turn->audio ms | grok ms | calendar ms |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for summary in summaries:
        call = str(summary.get("call_control_id") or "")[-12:]
        turn = _first_turn(summary)
        rows.append(
            "| {call} | {reason} | {events} | {webhook_audio} | {inbound_transcript} | {turn_audio} | {grok} | {calendar} |".format(
                call=call,
                reason=summary.get("reason") or "",
                events=summary.get("event_count") or 0,
                webhook_audio=_ms(summary, "webhook_to_first_assistant_audio_ms"),
                inbound_transcript=_ms(summary, "first_inbound_audio_to_first_final_transcript_ms"),
                turn_audio=turn.get("commit_to_first_audio_ms", ""),
                grok=turn.get("grok_ms", ""),
                calendar=turn.get("calendar_tool_ms", ""),
            )
        )
    return "\n".join(rows)


def _read_inputs(paths: list[str]) -> list[str]:
    if not paths:
        return list(sys.stdin)
    lines: list[str] = []
    for raw in paths:
        lines.extend(Path(raw).read_text(encoding="utf-8", errors="replace").splitlines())
    return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Summarize EchoDesk voice trace logs.")
    parser.add_argument("paths", nargs="*", help="Log files to scan. Reads stdin when omitted.")
    args = parser.parse_args(argv)
    summaries = parse_voice_trace_summaries(_read_inputs(args.paths))
    print(format_markdown_report(summaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
