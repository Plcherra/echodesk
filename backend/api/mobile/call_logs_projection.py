from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

# Shared call_logs projection tiers for mobile endpoints.
CALL_LOGS_CORE_COLUMNS = [
    "id",
    "call_control_id",
    "receptionist_id",
    "from_number",
    "to_number",
    "direction",
    "status",
    "started_at",
    "answered_at",
    "ended_at",
    "duration_seconds",
]
CALL_LOGS_EXTENDED_COLUMNS = [
    "cost_cents",
    "transcript",
]
CALL_LOGS_OPTIONAL_COLUMNS = [
    "outcome",
    "recording_status",
    "recording_url",
    "recorded_at",
    "recording_duration_seconds",
]

CALL_LOGS_CORE_SELECT = ", ".join(CALL_LOGS_CORE_COLUMNS)
CALL_LOGS_EXTENDED_SELECT = ", ".join(CALL_LOGS_CORE_COLUMNS + CALL_LOGS_EXTENDED_COLUMNS)
CALL_LOGS_FULL_SELECT = ", ".join(CALL_LOGS_CORE_COLUMNS + CALL_LOGS_EXTENDED_COLUMNS + CALL_LOGS_OPTIONAL_COLUMNS)


def is_missing_column_error(exc: BaseException) -> bool:
    msg = (str(exc) or "").lower()
    return (
        "does not exist" in msg
        or ("column" in msg and ("not found" in msg or "unknown" in msg or "could not find" in msg))
        or "schema cache" in msg
    )


def sanitize_call_rows(rows: list[Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for row in rows or []:
        safe = dict(row) if isinstance(row, dict) else {}
        if safe.get("duration_seconds") is None:
            safe["duration_seconds"] = 0
        out.append(safe)
    return out


def fetch_call_log_by_id_with_fallback(
    *,
    supabase,
    receptionist_id: str,
    call_id: str,
    diag_tag: str = "call-detail",
) -> tuple[dict[str, Any] | None, str, str | None]:
    """
    Fetch a single call_log row using full -> extended -> core projection fallback.
    Returns (row_or_none, select_mode, degraded_reason).
    None row means not found (query succeeded).
    """
    degraded_reason: str | None = None
    for mode, select_clause in (
        ("full", CALL_LOGS_FULL_SELECT),
        ("extended", CALL_LOGS_EXTENDED_SELECT),
        ("core", CALL_LOGS_CORE_SELECT),
    ):
        try:
            result = (
                supabase.table("call_logs")
                .select(select_clause)
                .eq("id", call_id)
                .eq("receptionist_id", receptionist_id)
                .limit(1)
                .execute()
            )
            rows = result.data if result and result.data is not None else []
            sanitized = sanitize_call_rows(rows)
            return (sanitized[0] if sanitized else None), mode, degraded_reason
        except Exception as e:
            if is_missing_column_error(e):
                degraded_reason = str(e)[:220]
                logger.warning(
                    "[CALL_HISTORY_SCHEMA_FALLBACK] tag=%s mode=%s call_id=%s error=%s",
                    diag_tag,
                    mode,
                    call_id,
                    degraded_reason,
                )
                continue
            raise
    raise RuntimeError("call_logs schema mismatch: no compatible projection")


def fetch_call_logs_with_fallback(
    *,
    supabase,
    receptionist_ids: list[str],
    limit: int,
    offset: int = 0,
    completed_only: bool = False,
    diag_tag: str = "call-history",
) -> tuple[list[dict[str, Any]], str, str | None]:
    """
    Fetch call_logs using full -> extended -> core projection fallback.
    Returns (rows, select_mode, degraded_reason).
    """
    degraded_reason: str | None = None
    for mode, select_clause in (
        ("full", CALL_LOGS_FULL_SELECT),
        ("extended", CALL_LOGS_EXTENDED_SELECT),
        ("core", CALL_LOGS_CORE_SELECT),
    ):
        try:
            query = (
                supabase.table("call_logs")
                .select(select_clause)
                .in_("receptionist_id", receptionist_ids)
                .order("started_at", desc=True)
            )
            if completed_only:
                query = query.eq("status", "completed")
            query = query.range(offset, offset + limit - 1) if offset > 0 else query.limit(limit)
            result = query.execute()
            rows = result.data if result and result.data is not None else []
            return sanitize_call_rows(rows), mode, degraded_reason
        except Exception as e:
            if is_missing_column_error(e):
                degraded_reason = str(e)[:220]
                logger.warning(
                    "[CALL_HISTORY_SCHEMA_FALLBACK] tag=%s mode=%s receptionist_ids=%s error=%s",
                    diag_tag,
                    mode,
                    ",".join(receptionist_ids[:3]),
                    degraded_reason,
                )
                continue
            raise
    raise RuntimeError("call_logs schema mismatch: no compatible projection")
