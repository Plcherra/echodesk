"""Configuration via pydantic-settings. Validates env at startup."""

import logging
import os
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

logger = logging.getLogger(__name__)
_supabase_deprecation_logged = False

# Load from project root (parent of backend/)
_root = Path(__file__).resolve().parent.parent
_env = _root / ".env"
_env_local = _root / ".env.local"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(_env_local) if _env_local.exists() else (str(_env) if _env.exists() else ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Supabase: prefer NEXT_PUBLIC_SUPABASE_URL (canonical), fallback to SUPABASE_URL (deprecated alias)
    supabase_url: str = ""  # Legacy: SUPABASE_URL
    supabase_service_role_key: str = ""
    next_public_supabase_url: str = ""  # Canonical: NEXT_PUBLIC_SUPABASE_URL
    next_public_supabase_anon_key: str = ""  # For JWT validation (outbound, etc.)

    # Telnyx
    telnyx_api_key: str = ""
    telnyx_connection_id: str = ""  # For outbound calls
    telnyx_public_key: str = ""  # For Ed25519 webhook verification
    telnyx_webhook_secret: str = ""  # For HMAC webhook verification
    telnyx_webhook_base_url: str = ""
    telnyx_stream_base_url: str = ""  # Optional: different URL for media stream
    telnyx_skip_verify: bool = False  # Skip webhook signature verification
    telnyx_allowed_ips: str = ""  # Optional comma-separated IPs when TELNYX_SKIP_VERIFY; empty = no allowlist
    telnyx_allow_receptionist_fallback: bool = False  # If True, use first active receptionist when DID unmatched (dangerous; keep False for verification so bad DID matches are not masked)
    telnyx_enable_recording: bool = True  # Attempt recording_start on call.answered
    # 10DLC / SMS: number must use a messaging profile before campaign link (Mission Control or API).
    telnyx_messaging_profile_id: str = ""
    telnyx_10dlc_use_mock: bool = False  # Telnyx mock brand/campaign (sandbox testing)
    telnyx_10dlc_default_usecase: str = "CUSTOMER_CARE"
    telnyx_10dlc_default_vertical: str = "RETAIL"
    # WhatsApp: portal handoff when Telnyx does not return an API signup session.
    telnyx_whatsapp_portal_url: str = ""  # e.g. https://portal.telnyx.com

    # Voice AI
    deepgram_api_key: str = ""
    deepgram_endpointing_ms: int = 250  # Env: DEEPGRAM_ENDPOINTING_MS
    deepgram_utterance_end_ms: int = 1000  # Env: DEEPGRAM_UTTERANCE_END_MS
    grok_api_key: str = ""

    # TTS provider: google (Google Cloud Text-to-Speech only)
    tts_provider: str = "google"  # Env: TTS_PROVIDER
    # Google Cloud TTS (ADC or GOOGLE_APPLICATION_CREDENTIALS)
    google_tts_voice_allowlist: str = ""  # Comma-separated voice names; empty = derive from presets + default
    google_tts_default_language_code: str = "en-US"  # Env: GOOGLE_TTS_DEFAULT_LANGUAGE_CODE
    google_tts_default_voice_name: str = "en-US-Neural2-C"  # Env: GOOGLE_TTS_DEFAULT_VOICE_NAME
    google_tts_backup_voice_name: str = "en-US-Neural2-A"  # Env: GOOGLE_TTS_BACKUP_VOICE_NAME
    google_tts_allow_premium_tiers: bool = False  # Env: GOOGLE_TTS_ALLOW_PREMIUM_TIERS (Studio, etc.)
    google_tts_speaking_rate: float = 1.22  # Env: GOOGLE_TTS_SPEAKING_RATE
    google_tts_pitch: float = 0.0  # Semitones -20..20; Env: GOOGLE_TTS_PITCH
    google_tts_preview_sample_rate_hertz: int = 24000  # MP3 preview; Env: GOOGLE_TTS_PREVIEW_SAMPLE_RATE_HERTZ
    # Cost / limits
    tts_chars_per_minute_estimate: float = 900.0  # Env: TTS_CHARS_PER_MINUTE_ESTIMATE
    tts_max_chars_per_utterance: int = 800  # Env: TTS_MAX_CHARS_PER_UTTERANCE
    tts_max_requests_per_call: int = 30  # Env: TTS_MAX_REQUESTS_PER_CALL
    tts_daily_char_cap: int = 0  # 0 = disabled; Env: TTS_DAILY_CHAR_CAP
    # Cache: none | memory | filesystem | redis_gcs
    tts_cache_backend: str = "filesystem"  # Env: TTS_CACHE_BACKEND
    tts_cache_ttl_seconds: int = 7776000  # 90 days; Env: TTS_CACHE_TTL_SECONDS
    tts_cache_memory_max_entries: int = 500  # Env: TTS_CACHE_MEMORY_MAX_ENTRIES
    tts_cache_filesystem_dir: str = "/tmp/echodesk-tts-cache"  # Env: TTS_CACHE_FILESYSTEM_DIR
    tts_cache_redis_url: str = ""  # Env: TTS_CACHE_REDIS_URL
    tts_cache_gcs_bucket: str = ""  # Env: TTS_CACHE_GCS_BUCKET
    tts_cache_gcs_prefix: str = "tts-cache/"  # Env: TTS_CACHE_GCS_PREFIX
    voice_combine_consent_and_greeting: bool = True  # Env: VOICE_COMBINE_CONSENT_AND_GREETING
    voice_debounce_ms: int = 1200  # Env: VOICE_DEBOUNCE_MS
    voice_debounce_fallback_ms: int = 800  # Env: VOICE_DEBOUNCE_FALLBACK_MS
    # Retries
    tts_google_max_retries: int = 5  # Env: TTS_GOOGLE_MAX_RETRIES
    tts_google_retry_base_seconds: float = 0.5  # Env: TTS_GOOGLE_RETRY_BASE_SECONDS
    tts_google_retry_max_seconds: float = 30.0  # Env: TTS_GOOGLE_RETRY_MAX_SECONDS
    # Chunking (mulaw bytes per WebSocket frame)
    tts_mulaw_chunk_bytes: int = 1600  # Env: TTS_MULAW_CHUNK_BYTES (~200ms at 8kHz mu-law)

    # Voice server
    voice_server_api_key: str = ""
    voice_prompt_base_url: str = ""  # Maps to VOICE_PROMPT_BASE_URL

    # App API (Next.js) for FCM push, quota checks
    app_api_base_url: str = ""
    internal_api_key: str = ""
    next_public_app_url: str = ""  # Fallback for app_api_base_url when co-located

    # Cron: optional, for triggering Next.js billing cron from this backend
    cron_secret: str = ""

    # Firebase (for backend FCM push)
    firebase_service_account_key: str = ""

    # Google Calendar OAuth
    google_client_id: str = ""
    google_client_secret: str = ""
    google_redirect_uri: str = ""
    next_public_google_redirect_uri: str = ""  # Alias for NEXT_PUBLIC_GOOGLE_REDIRECT_URI
    google_oauth_state_secret: str = ""  # For HMAC signing of OAuth state (fallback: supabase_service_role_key)

    # Stripe
    stripe_secret_key: str = ""
    stripe_webhook_secret: str = ""
    stripe_billing_portal_configuration_id: str = ""

    # Mobile app
    mobile_redirect_scheme: str = "echodesk"
    app_url: str = ""  # NEXT_PUBLIC_APP_URL or APP_URL for redirects

    # App
    port: int = 8000

    def model_post_init(self, __context) -> None:
        # Resolve app_api_base_url: fallback to NEXT_PUBLIC_APP_URL when unset
        if not self.app_api_base_url.strip() and self.next_public_app_url.strip():
            self.app_api_base_url = self.next_public_app_url.strip()
            logger.info(
                "APP_API_BASE_URL defaulting to NEXT_PUBLIC_APP_URL (%s)",
                self.app_api_base_url[:50],
            )
        # Resolve app_url for redirects
        if not self.app_url.strip() and self.next_public_app_url.strip():
            self.app_url = self.next_public_app_url.strip()

    def get_supabase_url(self) -> str:
        """Resolved Supabase URL. Prefer NEXT_PUBLIC_SUPABASE_URL, fallback to SUPABASE_URL (deprecated)."""
        global _supabase_deprecation_logged
        url = (self.next_public_supabase_url or self.supabase_url or "").strip()
        if self.supabase_url.strip() and not self.next_public_supabase_url.strip():
            if not _supabase_deprecation_logged:
                _supabase_deprecation_logged = True
                logger.warning(
                    "SUPABASE_URL is deprecated; use NEXT_PUBLIC_SUPABASE_URL instead"
                )
        return url

    def get_google_redirect_uri(self) -> str:
        return (self.google_redirect_uri or self.next_public_google_redirect_uri or "").strip()

    def get_app_url(self) -> str:
        return (self.app_url or self.next_public_app_url or "http://localhost:3000").strip().rstrip("/")

    def get_telnyx_ws_base(self) -> str:
        base = (
            (self.telnyx_stream_base_url or self.telnyx_webhook_base_url or "http://localhost:8000")
        ).rstrip("/")
        return base.replace("https://", "wss://").replace("http://", "ws://")

    def validate_voice_keys(self) -> None:
        """Fail fast if required voice keys missing."""
        missing = []
        if not self.deepgram_api_key:
            missing.append("DEEPGRAM_API_KEY")
        if not self.grok_api_key:
            missing.append("GROK_API_KEY")
        if missing:
            raise ValueError(f"Missing required env vars: {', '.join(missing)}")
        if os.environ.get("SKIP_GOOGLE_TTS_VALIDATION", "").strip() in ("1", "true", "yes"):
            return
        from voice.google_credentials import validate_google_tts_credentials
        validate_google_tts_credentials()

    def validate_supabase(self) -> None:
        """Fail fast if Supabase config missing."""
        url = self.get_supabase_url()
        key = (self.supabase_service_role_key or "").strip()
        anon_key = (self.next_public_supabase_anon_key or "").strip()
        if not url or not key:
            raise ValueError(
                "SUPABASE_URL (or NEXT_PUBLIC_SUPABASE_URL) and SUPABASE_SERVICE_ROLE_KEY must be set"
            )
        if not anon_key:
            raise ValueError(
                "NEXT_PUBLIC_SUPABASE_ANON_KEY must be set for /api/mobile JWT auth"
            )

    def validate_telnyx(self) -> None:
        """Fail fast if Telnyx API key missing (needed for voice webhook)."""
        if not (self.telnyx_api_key or "").strip():
            raise ValueError("TELNYX_API_KEY must be set for voice webhook")


settings = Settings()
