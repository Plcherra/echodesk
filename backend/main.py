"""FastAPI voice backend - WebSocket + HTTP routes."""

import sys
from pathlib import Path

# Ensure backend directory is on path for config, quota, etc.
_backend_dir = Path(__file__).resolve().parent
if str(_backend_dir) not in sys.path:
    sys.path.insert(0, str(_backend_dir))

# Load .env from project root (parent of backend/)
_root = _backend_dir.parent
_env = _root / ".env"
_env_local = _root / ".env.local"
if _env.exists():
    from dotenv import load_dotenv
    load_dotenv(_env)
if _env_local.exists():
    from dotenv import load_dotenv
    load_dotenv(_env_local)

import logging
import os
import asyncio
from contextlib import asynccontextmanager

import httpx
import stripe
from fastapi import FastAPI, Request, Header, HTTPException, WebSocket
from fastapi.responses import JSONResponse

from api.google_routes import google_callback_get
from api.admin_billing import router as admin_billing_router
from api.mobile_routes import router as mobile_router
from api.stripe_routes import stripe_webhook_post
from config import settings
from quota import check_outbound_quota
from voice.google_credentials import check_google_tts_credentials
from voice.handler import handle_voice_stream_connection
from telnyx.voice_webhook import handle_voice_webhook
from telnyx.cdr_webhook import handle_cdr_webhook
from api.outbound import create_outbound_call
from telnyx.voice_webhook_verify import (
    check_rate_limit,
    get_client_ip,
    record_verification_failure,
    verify_webhook_request,
)
from calendar_api.calendar_handler import handle_calendar_request
from prompts.fetch import _build_from_supabase_sync
from supabase_client import create_service_role_client

# Sentry: init when SENTRY_DSN is set (optional)
_sentry_dsn = (os.environ.get("SENTRY_DSN") or os.environ.get("NEXT_PUBLIC_SENTRY_DSN") or "").strip()
if _sentry_dsn:
    import sentry_sdk
    from sentry_sdk.integrations.fastapi import FastApiIntegration
    sentry_sdk.init(
        dsn=_sentry_dsn,
        integrations=[FastApiIntegration()],
        traces_sample_rate=0.1,
        environment=os.environ.get("SENTRY_ENVIRONMENT", "production"),
    )
    logging.getLogger(__name__).info("Sentry initialized")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


# Fingerprint to confirm deployed code (search logs for this)
VOICE_STREAM_VERSION = "v2026-03-stream-fix"


class WebSocketDebugMiddleware:
    """Log WebSocket connections at ASGI layer (before routing). Helps trace 403/90046."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") == "websocket":
            path = scope.get("path", "")
            qs = (scope.get("query_string") or b"").decode("utf-8", errors="replace")[:80]
            logger.info("[asgi] WebSocket scope received path=%s qs=%s", path, qs)
        await self.app(scope, receive, send)


@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        logger.info("[startup] Voice backend %s", VOICE_STREAM_VERSION)
        settings.validate_voice_keys()
        settings.validate_supabase()
        settings.validate_telnyx()
        logger.info(
            "[startup] Voice config: TTS_PROVIDER=google default_voice=%s backup_voice=%s speaking_rate=%s cache_backend=%s GROK_API_KEY=%s",
            (settings.google_tts_default_voice_name or "").strip(),
            (settings.google_tts_backup_voice_name or "").strip(),
            settings.google_tts_speaking_rate,
            settings.tts_cache_backend,
            "set" if (settings.grok_api_key or "").strip() else "not set",
        )
        logger.info(
            "[startup] Receptionist config precedence: system_prompt|custom else generated; "
            "greeting|custom else default; voice_id|receptionist else env_default; assistant_identity|receptionist else name"
        )
        if settings.telnyx_skip_verify:
            logger.warning(
                "SECURITY: TELNYX_SKIP_VERIFY is enabled. Webhook signature verification is DISABLED. "
                "Use only when headers are stripped by proxy (e.g. Cloudflare Tunnel). "
                "TELNYX_ALLOWED_IPS must be set (non-empty) or requests will be rejected."
            )
        # Warn if call_logs optional columns are missing (migrations 031, 032)
        try:
            supabase = create_service_role_client()
            supabase.table("call_logs").select(
                "id, outcome, recording_status, recording_url, recorded_at, recording_duration_seconds"
            ).limit(1).execute()
        except Exception as e:
            err_msg = (str(e) or "").lower()
            if "does not exist" in err_msg or ("column" in err_msg and ("not found" in err_msg or "unknown" in err_msg)):
                logger.warning(
                    "[startup] call_logs missing optional columns. Call history will use reduced schema. "
                    "Apply migrations: 031_call_logs_recording_fields.sql, 032_call_logs_outcome.sql"
                )
        try:
            supabase.table("appointments").select(
                "id, status, caller_number, call_log_id, confirmation_message_sent_at, payment_link_sent_at"
            ).limit(1).execute()
        except Exception as e:
            err_msg = (str(e) or "").lower()
            if "does not exist" in err_msg or ("column" in err_msg and ("not found" in err_msg or "unknown" in err_msg)):
                logger.warning(
                    "[startup] appointments missing optional columns (030). Appointments API will use reduced schema. "
                    "Apply migration: 030_appointment_review.sql"
                )
    except ValueError as e:
        logger.error("Startup validation failed: %s", e)
        raise
    yield
    logger.info("Shutting down")


app = FastAPI(title="Echodesk Voice Backend", lifespan=lifespan)
app.include_router(mobile_router)
app.include_router(admin_billing_router)


@app.get("/health")
@app.get("/api/health")
async def health() -> dict:
    supabase_status = "ok"
    try:
        supabase = create_service_role_client()
        supabase.table("users").select("id").limit(1).execute()
    except Exception as e:
        logger.warning("[health] Supabase check failed: %s", e)
        supabase_status = "error"
    payload: dict = {"status": "ok" if supabase_status == "ok" else "degraded", "supabase": supabase_status}
    payload["tts_provider"] = "google"
    tts_status, _ = check_google_tts_credentials()
    payload["tts_google"] = tts_status
    status = payload["status"]
    code = 503 if status == "degraded" else 200
    return JSONResponse(payload, status_code=code)


@app.get("/api/quota-check")
async def quota_check(request: Request):
    from api.auth import get_user_from_request
    user, supabase = get_user_from_request(request)
    if not user or not supabase:
        raise HTTPException(status_code=401, detail="Unauthorized")
    result = check_outbound_quota(supabase, user["id"])
    return result


@app.websocket("/ws-test")
async def ws_test(ws: WebSocket):
    """Minimal diagnostic route: splits 'all websockets broken' from 'only /api/voice/stream broken'."""
    logger.info("[ws-test] invoked")
    await ws.accept()
    await ws.send_text("ok")
    await ws.close()


@app.websocket("/api/voice/stream")
async def voice_stream(ws: WebSocket):
    # Always accept first; never call close() before accept() (that sends 403).
    try:
        logger.info("[voice/stream] Accepting WebSocket for %s", ws.scope.get("query_string", b"")[:80])
        await ws.accept()
        logger.info("[voice/stream] WebSocket accepted, entering handler")
        await handle_voice_stream_connection(ws)
    except Exception as e:
        logger.exception("[voice/stream] Error: %s", e)
        raise


@app.post(
    "/api/telnyx/voice",
    responses={
        200: {"description": "Webhook processed successfully"},
        400: {"description": "Invalid JSON body"},
        403: {
            "description": "Webhook signature verification failed",
            "content": {
                "application/json": {
                    "example": {
                        "detail": "Webhook signature verification failed",
                        "code": "webhook_verification_failed",
                    }
                }
            },
        },
        429: {"description": "Too many invalid signature attempts; try again later"},
    },
)
async def telnyx_voice(request: Request):
    raw = await request.body()
    headers = {k: v for k, v in request.headers.items()}
    client_ip = get_client_ip(headers, request.client.host if request.client else None)
    user_agent = headers.get("user-agent") or headers.get("User-Agent")

    ed25519_sig = headers.get("telnyx-signature-ed25519")
    timestamp = headers.get("telnyx-timestamp")
    hmac_sig = (
        headers.get("t-signature")
        or headers.get("telnyx-signature")
        or headers.get("x-telnyx-signature")
    )

    # Rate limit check before verification
    if await check_rate_limit(client_ip):
        logger.warning(
            "Telnyx webhook rate limited: too many failed attempts",
            extra={"client_ip": client_ip},
        )
        raise HTTPException(
            status_code=429,
            detail="Too many invalid signature attempts; try again later",
        )

    result = verify_webhook_request(
        raw,
        ed25519_sig=ed25519_sig,
        timestamp=timestamp,
        hmac_sig=hmac_sig,
        client_ip=client_ip,
        user_agent=user_agent,
    )

    if not result.verified:
        record_verification_failure(client_ip)
        raise HTTPException(
            status_code=403,
            detail=result.detail,
        )

    try:
        body = __import__("json").loads(raw.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")

    headers_dict = {k: v for k, v in request.headers.items()}
    result_response = await handle_voice_webhook(body, raw, headers_dict)
    return JSONResponse(result_response)


@app.post("/api/telnyx/cdr")
async def telnyx_cdr(request: Request):
    """Telnyx CDR webhook: call ended, insert usage, send call_ended push."""
    raw = await request.body()
    headers = {k: v for k, v in request.headers.items()}
    client_ip = get_client_ip(headers, request.client.host if request.client else None)
    user_agent = headers.get("user-agent") or headers.get("User-Agent")

    ed25519_sig = headers.get("telnyx-signature-ed25519")
    timestamp = headers.get("telnyx-timestamp")
    hmac_sig = (
        headers.get("t-signature")
        or headers.get("telnyx-signature")
        or headers.get("x-telnyx-signature")
    )

    if await check_rate_limit(client_ip):
        logger.warning("Telnyx CDR webhook rate limited", extra={"client_ip": client_ip})
        raise HTTPException(status_code=429, detail="Too many requests")

    result = verify_webhook_request(
        raw,
        ed25519_sig=ed25519_sig,
        timestamp=timestamp,
        hmac_sig=hmac_sig,
        client_ip=client_ip,
        user_agent=user_agent,
    )

    if not result.verified:
        record_verification_failure(client_ip)
        raise HTTPException(status_code=403, detail=result.detail)

    try:
        response = await handle_cdr_webhook(raw, headers)
        return JSONResponse(response)
    except Exception as e:
        logger.exception("CDR webhook error")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/telnyx/sms")
async def telnyx_sms_webhook(request: Request):
    """Telnyx messaging: message.received (inbound SMS booking), message.sent / message.finalized (delivery)."""
    raw = await request.body()
    headers = {k: v for k, v in request.headers.items()}
    client_ip = get_client_ip(headers, request.client.host if request.client else None)
    user_agent = headers.get("user-agent") or headers.get("User-Agent")

    ed25519_sig = headers.get("telnyx-signature-ed25519")
    timestamp = headers.get("telnyx-timestamp")
    hmac_sig = (
        headers.get("t-signature")
        or headers.get("telnyx-signature")
        or headers.get("x-telnyx-signature")
    )

    if await check_rate_limit(client_ip):
        logger.warning("Telnyx SMS webhook rate limited", extra={"client_ip": client_ip})
        raise HTTPException(status_code=429, detail="Too many requests")

    result = verify_webhook_request(
        raw,
        ed25519_sig=ed25519_sig,
        timestamp=timestamp,
        hmac_sig=hmac_sig,
        client_ip=client_ip,
        user_agent=user_agent,
    )

    if not result.verified:
        record_verification_failure(client_ip)
        raise HTTPException(status_code=403, detail=result.detail)

    from telnyx.sms_webhook import handle_sms_webhook

    response = handle_sms_webhook(raw)
    return JSONResponse(response)


@app.post("/api/telnyx/outbound")
async def telnyx_outbound(request: Request):
    """Initiate outbound call. Requires Bearer token. Body: { receptionist_id, to }."""
    auth = request.headers.get("authorization") or request.headers.get("Authorization") or ""
    if not auth.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Unauthorized")
    token = auth[7:].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Unauthorized")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")
    receptionist_id = (body.get("receptionist_id") or "").strip()
    to_phone = (body.get("to") or "").strip()
    if not receptionist_id or not to_phone:
        raise HTTPException(
            status_code=400,
            detail="receptionist_id and to (E.164) required",
        )
    return create_outbound_call(token, receptionist_id, to_phone)


@app.get("/api/receptionist-prompt")
async def receptionist_prompt(
    request: Request,
    x_voice_server_key: str = Header(None, alias="x-voice-server-key"),
    x_voice_api_key: str = Header(None, alias="x-voice-api-key"),
):
    receptionist_id = request.query_params.get("receptionist_id", "")
    api_key = settings.voice_server_api_key
    if not api_key or not api_key.strip():
        raise HTTPException(status_code=503, detail="Prompt API not configured")
    provided = x_voice_server_key or x_voice_api_key
    if provided != api_key:
        raise HTTPException(status_code=401, detail="Unauthorized")

    if not receptionist_id or not receptionist_id.strip():
        return {
            "prompt": "You are an AI receptionist. Be helpful and concise.",
            "greeting": "Hello! Thanks for calling. How can I help you today?",
        }

    supabase = create_service_role_client()
    rec_res = supabase.table("receptionists").select("id, status, active").eq("id", receptionist_id.strip()).execute()
    if not rec_res.data or len(rec_res.data) == 0:
        raise HTTPException(status_code=404, detail="Receptionist not found")
    rec = rec_res.data[0]
    if rec.get("status") != "active" or rec.get("active") is False:
        raise HTTPException(status_code=404, detail="Receptionist not found or inactive")
    prompt, greeting, *_ = _build_from_supabase_sync(receptionist_id, supabase)
    return {"prompt": prompt, "greeting": greeting}


@app.post("/api/voice/calendar")
async def voice_calendar(
    request: Request,
    x_voice_server_key: str = Header(None, alias="x-voice-server-key"),
    x_voice_api_key: str = Header(None, alias="x-voice-api-key"),
):
    api_key = settings.voice_server_api_key
    if not api_key or not api_key.strip():
        raise HTTPException(status_code=503, detail="Calendar API not configured")
    provided = x_voice_server_key or x_voice_api_key
    if provided != api_key:
        raise HTTPException(status_code=401, detail="Unauthorized")

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")

    return await handle_calendar_request(body)


@app.post("/api/stripe/webhook")
async def stripe_webhook(request: Request):
    return await stripe_webhook_post(request)


@app.get("/api/google/callback")
async def google_callback(request: Request):
    return await google_callback_get(request)


@app.get("/api/cron/payg-billing")
async def cron_payg_billing(
    authorization: str = Header(None, alias="Authorization"),
):
    """PAYG + overage billing for previous month. Run on 1st of month."""
    secret = (settings.cron_secret or "").strip()
    if not secret:
        raise HTTPException(status_code=503, detail="Cron not configured (CRON_SECRET required)")
    auth_val = authorization or ""
    if auth_val != f"Bearer {secret}":
        raise HTTPException(status_code=401, detail="Unauthorized")

    sk = (settings.stripe_secret_key or "").strip()
    if not sk:
        raise HTTPException(status_code=503, detail="Stripe not configured")
    stripe.api_key = sk

    try:
        from cron.usage_billing import (
            invoice_overage_for_fixed_plans,
            invoice_payg_for_previous_month,
            option_a_invoice_closed_periods,
        )
        supabase = create_service_role_client()
        payg_result = invoice_payg_for_previous_month(supabase, stripe)
        overage_result = invoice_overage_for_fixed_plans(supabase, stripe)
        option_a_result = option_a_invoice_closed_periods(supabase, stripe)
        return {
            "ok": True,
            "payg": payg_result,
            "overage": overage_result,
            "option_a": option_a_result,
        }
    except Exception as e:
        logger.exception("Cron payg-billing failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/cron/usage")
async def cron_usage(
    authorization: str = Header(None, alias="Authorization"),
):
    """Aggregate call_usage into usage_snapshots for current month. Run daily."""
    secret = (settings.cron_secret or "").strip()
    if not secret:
        raise HTTPException(status_code=503, detail="Cron not configured (CRON_SECRET required)")
    auth_val = authorization or ""
    if auth_val != f"Bearer {secret}":
        raise HTTPException(status_code=401, detail="Unauthorized")
    try:
        from cron.usage_aggregation import aggregate_usage_for_current_month
        supabase = create_service_role_client()
        result = aggregate_usage_for_current_month(supabase)
        return {"ok": True, "updated": result["updated"], "errors": result["errors"]}
    except Exception as e:
        logger.exception("Cron usage aggregation failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/cron/reset-usage")
async def cron_reset_usage(
    authorization: str = Header(None, alias="Authorization"),
):
    """Reset used_inbound_minutes and used_outbound_minutes for new period. Run on 1st of month.
    Only updates rows that have not yet been reset this month (period_reset_at < first day of current month, or null)
    to avoid accidentally resetting all users on a mistaken or repeated call."""
    secret = (settings.cron_secret or "").strip()
    if not secret:
        raise HTTPException(status_code=503, detail="Cron not configured (CRON_SECRET required)")
    auth_val = authorization or ""
    if auth_val != f"Bearer {secret}":
        raise HTTPException(status_code=401, detail="Unauthorized")

    from datetime import datetime
    now = datetime.utcnow()
    first_day_current_month = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    # Date-only boundary to avoid colon parsing risk in PostgREST query strings (e.g. 2026-03-01)
    first_day_boundary = first_day_current_month.strftime("%Y-%m-%d")
    ts = now.isoformat() + "Z"
    supabase = create_service_role_client()
    logger.info(
        "[cron/reset-usage] monthly filter: boundary=%s (period_reset_at IS NULL OR period_reset_at < first day of current month)",
        first_day_boundary,
    )
    # Only reset rows not yet reset this month (safety: prevents one mistaken call from resetting everyone)
    update_resp = (
        supabase.table("user_plans")
        .update({
            "used_inbound_minutes": 0,
            "used_outbound_minutes": 0,
            "period_reset_at": ts,
            "updated_at": ts,
        })
        .or_(f"period_reset_at.is.null,period_reset_at.lt.{first_day_boundary}")
        .execute()
    )
    count = len(update_resp.data) if update_resp.data else 0
    logger.info("[cron/reset-usage] reset count=%s (period_reset_at < %s or null)", count, first_day_boundary)
    return {"ok": True, "reset_count": count}


@app.get("/api/cron/billing-reconcile")
async def cron_billing_reconcile(
    authorization: str = Header(None, alias="Authorization"),
):
    """Backfill usage_ledger from billing_calls when webhooks were missed."""
    secret = (settings.cron_secret or "").strip()
    if not secret:
        raise HTTPException(status_code=503, detail="Cron not configured (CRON_SECRET required)")
    if (authorization or "") != f"Bearer {secret}":
        raise HTTPException(status_code=401, detail="Unauthorized")
    try:
        from cron.reconcile_usage import reconcile_missing_ledger_entries
        supabase = create_service_role_client()
        result = reconcile_missing_ledger_entries(supabase)
        return {"ok": True, **result}
    except Exception as e:
        logger.exception("Cron billing-reconcile failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/cron/usage-alerts")
async def cron_usage_alerts(
    authorization: str = Header(None, alias="Authorization"),
):
    """Usage threshold alerts (50/80/100/130% of included minutes)."""
    secret = (settings.cron_secret or "").strip()
    if not secret:
        raise HTTPException(status_code=503, detail="Cron not configured (CRON_SECRET required)")
    if (authorization or "") != f"Bearer {secret}":
        raise HTTPException(status_code=401, detail="Unauthorized")
    try:
        from cron.usage_alerts import run_usage_threshold_alerts
        supabase = create_service_role_client()
        result = run_usage_threshold_alerts(supabase)
        return {"ok": True, **result}
    except Exception as e:
        logger.exception("Cron usage-alerts failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))


# Wrap with debug middleware after all routes registered (uvicorn loads this)
app = WebSocketDebugMiddleware(app)

if __name__ == "__main__":
    import uvicorn
    port = getattr(settings, "port", 8000)
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=False)
