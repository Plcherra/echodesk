#!/usr/bin/env bash
# Deploy static landing page for echodesk.us
#
# Source:  landing/dist/  (repo path from project root)
# Target:  /var/www/echodesk-landing  (nginx document root for echodesk.us)
#
# Run from project root on VPS:
#   bash deploy/scripts/deploy-landing.sh
# Or (after chmod +x):  ./deploy/scripts/deploy-landing.sh
#
# Requires: rsync, sudo. Sets ownership to www-data for nginx.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="$ROOT/landing/dist"
TARGET_DIR="/var/www/echodesk-landing"
NGINX_USER="www-data"

echo "=== Deploy landing page ==="
echo "Source:  $SRC_DIR"
echo "Target:  $TARGET_DIR"

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: landing build output not found at: $SRC_DIR"
  echo "Expected static files (at least index.html) in landing/dist."
  exit 1
fi

if [ ! -f "$SRC_DIR/index.html" ]; then
  echo "ERROR: $SRC_DIR/index.html not found."
  echo "Ensure the landing page build output exists before deploying."
  exit 1
fi

echo "Creating target directory (if needed)..."
# Prefer passwordless wrapper when installed (install-landing-sudoers.sh).
if [ -x /usr/local/bin/echodesk-sync-landing ] && sudo -n /usr/local/bin/echodesk-sync-landing "$SRC_DIR" 2>/dev/null; then
  echo "=== Landing deploy complete (via echodesk-sync-landing) ==="
  echo "You should now see the updated landing at: https://echodesk.us"
  exit 0
fi

sudo mkdir -p "$TARGET_DIR"

echo "Syncing landing files to $TARGET_DIR ..."
sudo rsync -a --delete "$SRC_DIR"/ "$TARGET_DIR"/

echo "Setting ownership and permissions for nginx user ($NGINX_USER)..."
if id "$NGINX_USER" >/dev/null 2>&1; then
  sudo chown -R "$NGINX_USER:$NGINX_USER" "$TARGET_DIR"
else
  echo "WARNING: user '$NGINX_USER' not found; skipping chown."
fi

# Safe, read-only-ish permissions for static content
sudo find "$TARGET_DIR" -type d -exec chmod 755 {} \;
sudo find "$TARGET_DIR" -type f -exec chmod 644 {} \;

echo "=== Landing deploy complete ==="
echo "Deployed files:"
sudo find "$TARGET_DIR" -maxdepth 2 -type f -print | sed 's/^/  /'
echo
echo "You should now see the updated landing at: https://echodesk.us"

