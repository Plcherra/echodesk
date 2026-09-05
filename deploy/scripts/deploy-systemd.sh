#!/usr/bin/env bash
# Native systemd deploy for Echodesk on a VPS.
# Run from project root on the VPS: bash deploy/scripts/deploy-systemd.sh

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"

echo "=== Echodesk systemd deploy ==="
echo "Root: $ROOT"

bash scripts/check-docs.sh

[ -d venv ] || python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r backend/requirements.txt

# Node deps are minimal and only needed for helper scripts / legacy PM2 config.
npm install

echo "=== Validating environment ==="
./venv/bin/python scripts/validate-env.py

echo "=== Running migrations ==="
bash ./deploy/scripts/run-migrations.sh || {
  echo "WARNING: Migrations failed or skipped. Check DATABASE_URL."
}

if [ "${RUN_MIGRATION_CHECK:-0}" = "1" ]; then
  ./venv/bin/python scripts/check-migrations.py
fi

# Landing deploy uses sudo rsync/chown/chmod. Enable with DEPLOY_LANDING=1 (CI sets this).
# Soft-fail so a missing passwordless sudo rule does not block backend deploys.
if [ "${DEPLOY_LANDING:-0}" = "1" ]; then
  echo "=== Deploying landing ==="
  if bash ./deploy/scripts/deploy-landing.sh; then
    echo "Landing deploy OK"
  else
    echo "WARNING: landing deploy failed (often sudo). On the VPS run:"
    echo "  bash deploy/scripts/deploy-landing.sh"
    echo "Without this, https://echodesk.us/auth/callback falls back to the marketing homepage."
  fi
else
  echo "=== Skipping landing deploy (set DEPLOY_LANDING=1 to enable) ==="
fi

echo "=== Installing/restarting systemd service ==="
UNIT_SRC="$ROOT/deploy/systemd/echodesk-backend.service"
UNIT_DST="/etc/systemd/system/echodesk-backend.service"
# Only the unit-file install needs broad root (cp/daemon-reload/enable). A normal code
# deploy just needs `restart`, which is granted passwordless (setup-restart-sudoers.sh),
# so CI deploys don't require an interactive sudo password.
if cmp -s "$UNIT_SRC" "$UNIT_DST"; then
  echo "Unit file unchanged."
else
  echo "Unit file changed — attempting privileged install."
  if sudo -n cp "$UNIT_SRC" "$UNIT_DST" 2>/dev/null; then
    sudo -n systemctl daemon-reload
    sudo -n systemctl enable echodesk-backend
  else
    echo "WARNING: unit file changed but passwordless sudo is unavailable. Install manually:"
    echo "  sudo cp \"$UNIT_SRC\" \"$UNIT_DST\" && sudo systemctl daemon-reload && sudo systemctl enable echodesk-backend"
  fi
fi
sudo systemctl restart echodesk-backend

# Held-number detach timer. Install needs root; passwordless sudo is usually
# restart-only, so this warns and leaves the units for a one-time sudo install.
TIMER_SRC_DIR="$ROOT/deploy/systemd"
TIMER_UNITS=(
  echodesk-release-held-numbers.service
  echodesk-release-held-numbers.timer
)
TIMER_CHANGED=0
for unit in "${TIMER_UNITS[@]}"; do
  src="$TIMER_SRC_DIR/$unit"
  dst="/etc/systemd/system/$unit"
  if [[ -f "$src" ]] && ! cmp -s "$src" "$dst" 2>/dev/null; then
    TIMER_CHANGED=1
    if sudo -n cp "$src" "$dst" 2>/dev/null; then
      echo "Installed $unit"
    else
      echo "WARNING: could not install $unit (needs sudo). Manual:"
      echo "  sudo cp \"$src\" \"$dst\""
    fi
  fi
done
if [[ "$TIMER_CHANGED" -eq 1 ]]; then
  if sudo -n systemctl daemon-reload 2>/dev/null \
    && sudo -n systemctl enable --now echodesk-release-held-numbers.timer 2>/dev/null; then
    echo "Held-number timer enabled."
  else
    echo "WARNING: enable the held-number timer after copying units:"
    echo "  sudo systemctl daemon-reload"
    echo "  sudo systemctl enable --now echodesk-release-held-numbers.timer"
  fi
fi

sleep 3
curl -sS http://127.0.0.1:8000/api/health || true
echo

if [ -z "${SKIP_NGINX_SYNC:-}" ]; then
  echo "=== Syncing nginx config ==="
  bash ./deploy/scripts/sync-nginx-config.sh
else
  echo "=== Skipping nginx sync (SKIP_NGINX_SYNC=1) ==="
fi

if [ -z "${SKIP_VALIDATE_INFRA:-}" ]; then
  echo "=== Validating infrastructure ==="
  ./deploy/scripts/validate-infra-before-start.sh ${CI_MODE:+--ci}
else
  echo "=== Skipping infrastructure validation (SKIP_VALIDATE_INFRA=1) ==="
fi

echo "=== Deploy done ==="
# status doesn't need root; tolerate non-zero exit so it never fails the deploy.
systemctl status echodesk-backend --no-pager || true
