"""Google OAuth callback for Calendar connection."""

from __future__ import annotations

import hmac
import hashlib
import logging
import time
from datetime import datetime

from fastapi import Request
from fastapi.responses import HTMLResponse, RedirectResponse

from config import settings
from google_oauth_scopes import SCOPES
from supabase_client import create_service_role_client

logger = logging.getLogger(__name__)

def _mobile_success_html(deep_link: str) -> str:
    safe = deep_link.replace('"', "%22").replace("<", "%3C").replace(">", "%3E")
    return f"""<!DOCTYPE html>
<html>
<head>
  <title>Calendar Connected</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body {{
      font-family: system-ui, -apple-system, sans-serif;
      background: #111;
      color: white;
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100vh;
      margin: 0;
      text-align: center;
    }}
    .box {{
      max-width: 420px;
      padding: 32px;
      background: #1c1c1c;
      border-radius: 12px;
      box-shadow: 0 10px 30px rgba(0,0,0,0.45);
    }}
    h2 {{ margin: 0 0 12px; }}
    p {{ margin: 10px 0; opacity: 0.92; }}
    a {{
      display: inline-block;
      margin-top: 18px;
      padding: 10px 14px;
      color: white;
      background: #4f46e5;
      border-radius: 8px;
      text-decoration: none;
      font-weight: 600;
    }}
    .muted {{ opacity: 0.75; font-size: 14px; }}
  </style>
</head>
<body>
  <div class="box">
    <h2>Calendar Connected</h2>
    <p>Your Google Calendar is now linked to Echodesk.</p>
    <p class="muted">Returning to the app...</p>
    <a href="{safe}">Open Echodesk</a>
  </div>

  <script>
    window.location.href = "{safe}";
    setTimeout(() => {{ window.close(); }}, 1800);
  </script>
</body>
</html>
"""

def _error_html(msg: str) -> str:
    safe = (msg or "Calendar connection failed").replace("<", "&lt;").replace(">", "&gt;")
    return f"""<!DOCTYPE html>
<html>
<head>
  <title>Calendar Connection Failed</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body {{
      font-family: system-ui, -apple-system, sans-serif;
      background: #111;
      color: white;
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100vh;
      margin: 0;
      text-align: center;
    }}
    .box {{
      max-width: 520px;
      padding: 32px;
      background: #1c1c1c;
      border-radius: 12px;
      box-shadow: 0 10px 30px rgba(0,0,0,0.45);
    }}
    h2 {{ margin: 0 0 12px; }}
    p {{ margin: 10px 0; opacity: 0.92; }}
    code {{
      display: inline-block;
      padding: 2px 6px;
      background: rgba(255,255,255,0.08);
      border-radius: 6px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 13px;
      word-break: break-word;
    }}
    .muted {{ opacity: 0.75; font-size: 14px; }}
  </style>
</head>
<body>
  <div class="box">
    <h2>Calendar Connection Failed</h2>
    <p class="muted">You can close this page and try again.</p>
    <p><code>{safe}</code></p>
  </div>
</body>
</html>"""


async def google_callback_get(request: Request):
    """Handle Google OAuth callback. Exchange code for tokens, save to users, redirect to app."""
    redirect_uri = settings.get_google_redirect_uri()
    client_id = (settings.google_client_id or "").strip()
    client_secret = (settings.google_client_secret or "").strip()
    if not redirect_uri or not client_id or not client_secret:
        logger.error("[Google callback] Missing OAuth config")
        return _redirect_error("Server configuration error")

    code = request.query_params.get("code")
    raw_state = request.query_params.get("state")
    error = request.query_params.get("error")
    if error:
        return _redirect_error(f"OAuth error: {error}")
    if not code:
        return _redirect_error("Missing authorization code")
    if not raw_state:
        return _redirect_error("Missing state parameter")

    # Verify signed state (CSRF protection: state is payload.signature)
    state_parts = raw_state.split(".", 1)
    if len(state_parts) != 2:
        logger.warning("[Google callback] Invalid state format (expected payload.signature)")
        return _redirect_error("Invalid state parameter")
    payload, signature = state_parts
    secret = (settings.google_oauth_state_secret or settings.supabase_service_role_key or "").encode("utf-8")
    if not secret:
        logger.error("[Google callback] OAuth state secret not configured")
        return _redirect_error("Server configuration error")
    expected_sig = hmac.new(secret, payload.encode("utf-8"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected_sig, signature):
        logger.warning("[Google callback] State signature mismatch")
        return _redirect_error("Invalid state parameter")
    payload_parts = payload.split(":")
    if len(payload_parts) < 3:
        logger.warning("[Google callback] State payload missing user_id:return_to:timestamp")
        return _redirect_error("Invalid state parameter")
    user_id = payload_parts[0]
    return_to = payload_parts[1] if len(payload_parts) > 2 else "dashboard"
    try:
        state_ts = int(payload_parts[2])
        if abs(time.time() - state_ts) > 600:
            logger.warning("[Google callback] State expired (timestamp %s)", state_ts)
            return _redirect_error("Link expired. Please try connecting again.")
    except (ValueError, IndexError):
        return _redirect_error("Invalid state parameter")

    logger.info(
        "[Google callback] received code=%s state_return_to=%s redirect_uri=%r",
        "set" if code else "missing",
        return_to,
        redirect_uri,
    )

    supabase = create_service_role_client()
    r = supabase.table("users").select("id").eq("id", user_id).limit(1).execute()
    if not r.data or len(r.data) == 0:
        return _redirect_error("Invalid user", return_to)

    try:
        from google_auth_oauthlib.flow import Flow
        from google.oauth2.credentials import Credentials
        from googleapiclient.discovery import build

        flow = Flow.from_client_config(
            {
                "web": {
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                    "token_uri": "https://oauth2.googleapis.com/token",
                    "redirect_uris": [redirect_uri],
                }
            },
            scopes=SCOPES,
            redirect_uri=redirect_uri,
            # Keep consistent with /api/mobile/google-auth-url: server-side OAuth without PKCE.
            autogenerate_code_verifier=False,
        )

        logger.info(
            "[Google callback] token_exchange pkce_enabled=%s (code_verifier_present=%s)",
            bool(getattr(flow, "code_verifier", None)),
            "yes" if getattr(flow, "code_verifier", None) else "no",
        )
        logger.info("[Google callback] scopes=%s", " ".join(SCOPES))
        flow.fetch_token(code=code)
        credentials = flow.credentials
        if not credentials.refresh_token:
            return _redirect_error("No refresh token received. Please try connecting again and grant all permissions.", return_to)

        oauth2 = build("oauth2", "v2", credentials=credentials)
        userinfo = oauth2.userinfo().get().execute()
        calendar_id = userinfo.get("email", "primary") or "primary"

        supabase.table("users").update({
            "calendar_id": calendar_id,
            "calendar_refresh_token": credentials.refresh_token,
            "updated_at": datetime.utcnow().isoformat() + "Z",
        }).eq("id", user_id).execute()
        logger.info("[Google callback] Connected calendar for user %s", user_id)

        scheme = settings.mobile_redirect_scheme
        is_mobile = return_to in ("mobile", "settings")
        if is_mobile:
            deep_link = f"{scheme}://google-callback?success=1"
            return HTMLResponse(_mobile_success_html(deep_link))
        app_url = settings.get_app_url()
        path = "/onboarding" if return_to == "onboarding" else ("/receptionists" if return_to == "receptionists" else "/dashboard")
        return RedirectResponse(url=f"{app_url}{path}?calendar=connected")
    except Exception as e:
        logger.exception("[Google callback] %s", e)
        msg = f"Connection failed: {e}"
        if return_to in ("mobile", "settings"):
            return HTMLResponse(_error_html(msg), status_code=400)
        return _redirect_error(msg, return_to)


def _redirect_error(msg: str, return_to: str = "dashboard"):
    scheme = settings.mobile_redirect_scheme
    app_url = settings.get_app_url()
    is_mobile = return_to in ("mobile", "settings")
    if is_mobile:
        return RedirectResponse(url=f"{scheme}://google-callback?success=0&error={_encode(msg)}")
    path = "/onboarding" if return_to == "onboarding" else ("/receptionists" if return_to == "receptionists" else "/dashboard")
    return RedirectResponse(url=f"{app_url}{path}?calendar=error&message={_encode(msg)}")


def _encode(s: str) -> str:
    from urllib.parse import quote
    return quote(s, safe="")
