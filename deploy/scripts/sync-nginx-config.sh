#!/bin/bash
# Sync nginx config from repo templates. Picks full (SSL) or http-only based on cert.
# Run from project root: ./deploy/scripts/sync-nginx-config.sh
#
# Use when: deploy fails on "nginx config invalid" or after pulling nginx template changes.

set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

SSL_CERT="/etc/letsencrypt/live/echodesk.us/fullchain.pem"
FULL_TEMPLATE="$ROOT/deploy/nginx/callbot.conf.template"
HTTP_TEMPLATE="$ROOT/deploy/nginx/callbot-http-only.conf.template"
NGINX_SITE="/etc/nginx/sites-available/callbot"

echo "=== Syncing nginx config ==="

# Match deploy-landing.sh: production docroot is /var/www/echodesk-landing. Prefer it when
# present so nginx and rsync target stay aligned; otherwise use repo landing/dist (local/dev).
PROD_LANDING="/var/www/echodesk-landing"
if [ -d "$PROD_LANDING" ]; then
  LANDING_ROOT="$PROD_LANDING"
  echo "LANDING_ROOT=$LANDING_ROOT (production docroot)"
else
  LANDING_ROOT="$ROOT/landing/dist"
  echo "LANDING_ROOT=$LANDING_ROOT (repo fallback; run deploy-landing.sh on VPS for production path)"
fi

if [ ! -d "$LANDING_ROOT" ]; then
  echo "ERROR: LANDING_ROOT is not a directory: $LANDING_ROOT"
  exit 1
fi
for f in privacy.html terms.html opt-in.html auth/callback/index.html; do
  if [ ! -f "$LANDING_ROOT/$f" ]; then
    echo "ERROR: Required landing page missing: $LANDING_ROOT/$f"
    echo "Ensure landing/dist contains it, then run: bash deploy/scripts/deploy-landing.sh"
    exit 1
  fi
done
echo "OK: $LANDING_ROOT privacy, terms, opt-in, and auth/callback present"

# Use sudo so cert check works when run by deploy/user (letsencrypt dir may restrict access)
if [ -f "$SSL_CERT" ] || sudo test -f "$SSL_CERT" 2>/dev/null; then
  echo "SSL cert found: using full config (port 80 redirect + 443)"
  sed "s|{{LANDING_ROOT}}|$LANDING_ROOT|g" "$FULL_TEMPLATE" | sudo tee "$NGINX_SITE" > /dev/null
else
  echo "SSL cert not found at $SSL_CERT – using http-only config (no 443; wss://stream.echodesk.us will fail)"
  sed "s|{{LANDING_ROOT}}|$LANDING_ROOT|g" "$HTTP_TEMPLATE" | sudo tee "$NGINX_SITE" > /dev/null
fi

sudo ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/

echo "Testing nginx config..."
if ! sudo nginx -t; then
  echo "ERROR: nginx config invalid. Check: sudo nginx -t"
  exit 1
fi

sudo systemctl reload nginx
echo "nginx config synced and reloaded."
