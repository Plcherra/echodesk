#!/usr/bin/env bash
# Run Echodesk mobile against production without typing dart-define flags.
# Usage:
#   ./run_prod.sh [device] [debug|profile|release]
# Examples:
#   ./run_prod.sh macos profile
#   ./run_prod.sh chrome debug
#   ./run_prod.sh <iphone-device-id> release   # true release build on a tethered device
# Find your device id with: flutter devices
#
# Env resolution order:
#   1. Process env (SUPABASE_URL, SUPABASE_ANON_KEY, API_BASE_URL, …)
#   2. Local ../.env.local (optional)
#   3. VPS public keys via SSH (NEXT_PUBLIC_SUPABASE_* / SUPABASE_*)
# Disable VPS fallback: MOBILE_RELEASE_USE_VPS_ENV=false

set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="../.env.local"
MOBILE_RELEASE_USE_VPS_ENV="${MOBILE_RELEASE_USE_VPS_ENV:-true}"
VPS_SSH_TARGET="${VPS_SSH_TARGET:-echodesk-vps}"
# Production env on the VPS (deploy README: /opt/echodesk/app/.env)
VPS_ENV_FILE="${VPS_ENV_FILE:-/opt/echodesk/app/.env}"

get_var() {
  local key="$1"
  if [ ! -f "$ENV_FILE" ]; then
    return 0
  fi
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

vps_public_env() {
  if [ "${MOBILE_RELEASE_USE_VPS_ENV}" != "true" ]; then
    return 0
  fi

  ssh "${VPS_SSH_TARGET}" \
    "for f in '${VPS_ENV_FILE}' '${VPS_ENV_FILE}.local' /opt/echodesk/app/.env.local; do
       [ -f \"\$f\" ] || continue
       awk -F= '
         \$0 !~ /^[[:space:]]*#/ && (
           \$1 == \"NEXT_PUBLIC_SUPABASE_URL\" ||
           \$1 == \"SUPABASE_URL\" ||
           \$1 == \"NEXT_PUBLIC_SUPABASE_ANON_KEY\" ||
           \$1 == \"SUPABASE_ANON_KEY\" ||
           \$1 == \"APP_API_BASE_URL\" ||
           \$1 == \"NEXT_PUBLIC_APP_URL\" ||
           \$1 == \"APP_URL\" ||
           \$1 == \"NEXT_PUBLIC_GOOGLE_AUTH_ENABLED\" ||
           \$1 == \"GOOGLE_AUTH_ENABLED\"
         ) {
           value = substr(\$0, index(\$0, \"=\") + 1)
           gsub(/^[[:space:]]+|[[:space:]]+$/, \"\", value)
           gsub(/^\"|\"$/, \"\", value)
           gsub(/^'\''|'\''$/, \"\", value)
           print \$1 \"=\" value
         }
       ' \"\$f\"
     done" 2>/dev/null || true
}

apply_vps_public_env() {
  if { [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_ANON_KEY:-}" ]; }; then
    return 0
  fi

  local line key value
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      NEXT_PUBLIC_SUPABASE_URL|SUPABASE_URL)
        SUPABASE_URL="${SUPABASE_URL:-${value}}"
        ;;
      NEXT_PUBLIC_SUPABASE_ANON_KEY|SUPABASE_ANON_KEY)
        SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-${value}}"
        ;;
      APP_API_BASE_URL|NEXT_PUBLIC_APP_URL|APP_URL)
        API_URL="${API_URL:-${value}}"
        ;;
      NEXT_PUBLIC_GOOGLE_AUTH_ENABLED|GOOGLE_AUTH_ENABLED)
        GOOGLE_AUTH_ENABLED="${GOOGLE_AUTH_ENABLED:-${value}}"
        ;;
    esac
  done < <(vps_public_env)
}

API_URL="${API_BASE_URL:-$(get_var "APP_API_BASE_URL")}"
API_URL="${API_URL:-$(get_var "NEXT_PUBLIC_APP_URL")}"
API_URL="${API_URL:-$(get_var "APP_URL")}"

SUPABASE_URL="${SUPABASE_URL:-$(get_var "NEXT_PUBLIC_SUPABASE_URL")}"
SUPABASE_URL="${SUPABASE_URL:-$(get_var "SUPABASE_URL")}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-$(get_var "NEXT_PUBLIC_SUPABASE_ANON_KEY")}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-$(get_var "SUPABASE_ANON_KEY")}"
GOOGLE_AUTH_ENABLED="${GOOGLE_AUTH_ENABLED:-$(get_var "NEXT_PUBLIC_GOOGLE_AUTH_ENABLED")}"
GOOGLE_AUTH_ENABLED="${GOOGLE_AUTH_ENABLED:-$(get_var "GOOGLE_AUTH_ENABLED")}"

apply_vps_public_env

API_URL="${API_URL:-https://echodesk.us}"
GOOGLE_AUTH_ENABLED="${GOOGLE_AUTH_ENABLED:-false}"

if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_ANON_KEY:-}" ]; then
  echo "Need NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY." >&2
  echo "Set them in ../.env.local, export them, or allow VPS fallback." >&2
  echo "VPS fallback reads public keys from ${VPS_SSH_TARGET}:${VPS_ENV_FILE}." >&2
  echo "Set MOBILE_RELEASE_USE_VPS_ENV=false to disable VPS fallback." >&2
  exit 1
fi

case "$SUPABASE_URL" in
  *your-project.supabase.co*|*"your_project"*)
    echo "ERROR: SUPABASE_URL is still the placeholder: $SUPABASE_URL"
    echo "Edit ../.env.local with your real Supabase project URL (Project Settings → API)."
    exit 1
    ;;
esac
if echo "$SUPABASE_ANON_KEY" | grep -qiE 'your_anon|changeme|replace'; then
  echo "ERROR: SUPABASE_ANON_KEY looks like a placeholder. Fix ../.env.local."
  exit 1
fi

DEVICE="${1:-macos}"
MODE="${2:-debug}"
MODE_FLAG=()
case "$MODE" in
  debug) ;;
  profile) MODE_FLAG=(--profile) ;;
  release) MODE_FLAG=(--release) ;;
  *)
    echo "Unknown mode '$MODE'. Use debug, profile, or release."
    exit 1
    ;;
esac

if [ -f "$ENV_FILE" ]; then
  echo "Using local env: $ENV_FILE"
else
  echo "No local ../.env.local — using VPS public env from ${VPS_SSH_TARGET}"
fi

echo "Running Echodesk Mobile against $API_URL on $DEVICE ($MODE)"

# Refresh iOS/Android launcher + splash from assets/icon (logo changes need this).
if [ "${SKIP_ICON_GEN:-0}" != "1" ]; then
  echo "Regenerating launcher icons + splash…"
  dart run flutter_launcher_icons
  dart run flutter_native_splash:create
fi

exec flutter run -d "$DEVICE" "${MODE_FLAG[@]}" \
  --dart-define=API_BASE_URL="$API_URL" \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
  --dart-define=GOOGLE_AUTH_ENABLED="$GOOGLE_AUTH_ENABLED"
