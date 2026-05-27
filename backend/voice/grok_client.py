"""Grok (xAI) API client via httpx."""

import json
import logging
import time
from typing import Any, Callable, Awaitable

import httpx
from voice.trace import mark_voice_event

GROK_API = "https://api.x.ai/v1"

MAX_TOOL_ROUNDS = 5

logger = logging.getLogger(__name__)

GROK_FALLBACK_REPLY = "I'm having trouble connecting right now. Please try again in a moment."


def _log_grok_request(model: str, api_key: str, endpoint: str = "chat/completions") -> None:
    """Fail-fast logging for Grok/xAI requests."""
    logger.info(
        "[Grok] base_url=%s endpoint=%s model=%s api_key_present=%s",
        GROK_API,
        endpoint,
        model,
        bool(api_key and api_key.strip()),
    )


async def chat(
    messages: list[dict[str, Any]],
    api_key: str,
    model: str = "grok-3-mini",
    *,
    trace_call_id: str | None = None,
    trace_commit_id: int | None = None,
) -> str:
    """Chat completion with Grok (no tools). Returns fallback string on 403."""
    _log_grok_request(model, api_key)
    async with httpx.AsyncClient(timeout=60.0) as client:
        t0 = time.perf_counter()
        mark_voice_event(
            trace_call_id,
            "grok_request_sent",
            commit_id=trace_commit_id,
            model=model,
            endpoint="chat/completions",
            tool_round=0,
            tools=False,
        )
        resp = await client.post(
            f"{GROK_API}/chat/completions",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": model,
                "messages": [
                    {"role": m["role"], "content": m.get("content") or ""}
                    for m in messages
                ],
                "max_tokens": 120,
                "temperature": 0.3,
            },
        )
        if resp.status_code == 403:
            logger.warning(
                "[Grok] 403 Forbidden - check xAI credits/billing. Using fallback reply."
            )
            mark_voice_event(
                trace_call_id,
                "grok_response_received",
                commit_id=trace_commit_id,
                status_code=resp.status_code,
                duration_ms=int((time.perf_counter() - t0) * 1000),
                fallback=True,
            )
            return GROK_FALLBACK_REPLY
        resp.raise_for_status()
        data = resp.json()
        content = (
            data.get("choices", [{}])[0].get("message", {}).get("content") or ""
        )
        mark_voice_event(
            trace_call_id,
            "grok_response_received",
            commit_id=trace_commit_id,
            status_code=resp.status_code,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            content_len=len(content),
            fallback=False,
        )
        return content.strip()


def _format_message(m: dict[str, Any]) -> dict[str, Any]:
    if m.get("tool_calls"):
        return {
            "role": "assistant",
            "content": m.get("content"),
            "tool_calls": [
                {
                    "id": tc["id"],
                    "type": "function",
                    "function": {
                        "name": tc["function"]["name"],
                        "arguments": tc["function"]["arguments"],
                    },
                }
                for tc in m["tool_calls"]
            ],
        }
    return {"role": m["role"], "content": m.get("content") or ""}


async def chat_with_tools(
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]],
    tool_executor: Callable[[str, dict[str, Any]], Awaitable[str]],
    api_key: str,
    model: str = "grok-3-mini",
    *,
    trace_call_id: str | None = None,
    trace_commit_id: int | None = None,
) -> str:
    """Chat with function calling. Executes tools and loops until final text. Returns fallback on 403."""
    _log_grok_request(model, api_key, "chat/completions (tools)")
    history = list(messages)
    async with httpx.AsyncClient(timeout=60.0) as client:
        for tool_round in range(MAX_TOOL_ROUNDS):
            t0 = time.perf_counter()
            mark_voice_event(
                trace_call_id,
                "grok_request_sent",
                commit_id=trace_commit_id,
                model=model,
                endpoint="chat/completions",
                tool_round=tool_round,
                tools=True,
            )
            resp = await client.post(
                f"{GROK_API}/chat/completions",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model,
                    "messages": [_format_message(m) for m in history],
                    "tools": tools,
                    "tool_choice": "auto",
                    "max_tokens": 150,
                    "temperature": 0.3,
                },
            )
            if resp.status_code == 403:
                logger.warning(
                    "[Grok] 403 Forbidden - check xAI credits/billing. Using fallback reply."
                )
                mark_voice_event(
                    trace_call_id,
                    "grok_response_received",
                    commit_id=trace_commit_id,
                    status_code=resp.status_code,
                    duration_ms=int((time.perf_counter() - t0) * 1000),
                    tool_round=tool_round,
                    fallback=True,
                )
                return GROK_FALLBACK_REPLY
            resp.raise_for_status()
            data = resp.json()
            msg = data.get("choices", [{}])[0].get("message")
            if not msg:
                mark_voice_event(
                    trace_call_id,
                    "grok_response_received",
                    commit_id=trace_commit_id,
                    status_code=resp.status_code,
                    duration_ms=int((time.perf_counter() - t0) * 1000),
                    tool_round=tool_round,
                    content_len=0,
                    tool_calls=0,
                )
                return ""

            tool_calls = msg.get("tool_calls") or []
            content = msg.get("content") or ""
            mark_voice_event(
                trace_call_id,
                "grok_response_received",
                commit_id=trace_commit_id,
                status_code=resp.status_code,
                duration_ms=int((time.perf_counter() - t0) * 1000),
                tool_round=tool_round,
                content_len=len(content),
                tool_calls=len(tool_calls),
                fallback=False,
            )
            if not tool_calls:
                return content.strip()

            history.append({
                "role": "assistant",
                "content": msg.get("content"),
                "tool_calls": tool_calls,
            })

            for tc in tool_calls:
                name = tc["function"]["name"]
                try:
                    args = json.loads(tc["function"].get("arguments") or "{}")
                except json.JSONDecodeError:
                    args = {}
                try:
                    result = await tool_executor(name, args)
                    content = result if isinstance(result, str) else json.dumps(result)
                except Exception as e:
                    content = json.dumps({"success": False, "error": str(e)})
                history.append({
                    "role": "tool",
                    "tool_call_id": tc["id"],
                    "content": content,
                })

    return "I'm sorry, I'm having trouble with that. Could you try again?"
