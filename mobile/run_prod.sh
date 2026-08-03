#!/usr/bin/env bash
# Run Echodesk mobile against production without typing dart-define flags.
# Usage:
#   ./run_prod.sh [device] [debug|profile|release]
# Examples:
#   ./run_prod.sh macos profile
#   ./run_prod.sh chrome debug
#   ./run_prod.sh <iphone-device-id> release   # true release build on a tethered device
# Find your device id with: flutter devices

set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="../.env.local"
if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Copy ../.env.local.example and fill production values."
  exit 1
fi

get_var() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

API_URL="${API_BASE_URL:-$(get_var "APP_API_BASE_URL")}"
API_URL="${API_URL:-$(get_var "NEXT_PUBLIC_APP_URL")}"
API_URL="${API_URL:-https://echodesk.us}"

SUPABASE_URL="${SUPABASE_URL:-$(get_var "NEXT_PUBLIC_SUPABASE_URL")}"
SUPABASE_URL="${SUPABASE_URL:-$(get_var "SUPABASE_URL")}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-$(get_var "NEXT_PUBLIC_SUPABASE_ANON_KEY")}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-$(get_var "SUPABASE_ANON_KEY")}"
GOOGLE_AUTH_ENABLED="${GOOGLE_AUTH_ENABLED:-$(get_var "NEXT_PUBLIC_GOOGLE_AUTH_ENABLED")}"
GOOGLE_AUTH_ENABLED="${GOOGLE_AUTH_ENABLED:-$(get_var "GOOGLE_AUTH_ENABLED")}"
GOOGLE_AUTH_ENABLED="${GOOGLE_AUTH_ENABLED:-false}"

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
  echo "Need NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY in ../.env.local"
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
