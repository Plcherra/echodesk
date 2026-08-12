#!/bin/bash
# Run Flutter app with env from project .env.local
# Usage: ./run.sh [device]   e.g. ./run.sh macos

set -e
cd "$(dirname "$0")"

ENV_FILE="../.env.local"
if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Copy from .env.local.example and fill in values."
  exit 1
fi

get_var() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || echo ""
}

API_URL=$(get_var "NEXT_PUBLIC_APP_URL")
SUPABASE_URL=$(get_var "NEXT_PUBLIC_SUPABASE_URL")
SUPABASE_ANON=$(get_var "NEXT_PUBLIC_SUPABASE_ANON_KEY")

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON" ]; then
  echo "Need NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY in .env.local"
  exit 1
fi

case "$SUPABASE_URL" in
  *your-project.supabase.co*|*"your_project"*)
    echo "ERROR: SUPABASE_URL is still the placeholder: $SUPABASE_URL"
    echo "Edit ../.env.local with your real Supabase project URL (Project Settings → API)."
    exit 1
    ;;
esac

API_URL=${API_URL:-http://localhost:3000}
DEVICE=${1:-macos}

exec flutter run -d "$DEVICE" \
  --dart-define=API_BASE_URL="$API_URL" \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON"
