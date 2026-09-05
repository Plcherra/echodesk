#!/usr/bin/env bash
# Detach unused held DIDs from customer accounts. Does not delete numbers in Telnyx.
# Safe to run repeatedly. Used by the systemd timer and as a manual/crontab fallback.
set -euo pipefail

ENV_FILE="${ECHO_DESK_ENV:-/opt/echodesk/app/.env}"
CRON_URL="${ECHO_DESK_CRON_URL:-http://127.0.0.1:8000/api/cron/release-held-numbers}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing env file: $ENV_FILE" >&2
  exit 1
fi

# Read only CRON_SECRET. Do not source the whole .env.
CRON_SECRET="$(sed -n 's/^CRON_SECRET=//p' "$ENV_FILE" | head -n 1 | tr -d '"' | tr -d "'" | tr -d '\r')"
if [[ -z "$CRON_SECRET" ]]; then
  echo "CRON_SECRET is empty in $ENV_FILE" >&2
  exit 1
fi

exec curl -fsS -H "Authorization: Bearer ${CRON_SECRET}" "$CRON_URL"
