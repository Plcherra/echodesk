#!/usr/bin/env bash
# Pull latest code and restart the EchoDesk backend (systemd service).
#
# Run as the deploy user (echodesk) on the VPS:
#   ssh echodesk@<vps>
#   /opt/echodesk/app/deploy/scripts/vps_restart.sh
#
# Restarting the systemd service needs sudo. Grant a one-time passwordless rule with:
#   sudo bash /opt/echodesk/app/deploy/scripts/setup-restart-sudoers.sh
# Without it, sudo will prompt for a password (which still works, just not one-shot).

set -euo pipefail

SERVICE="echodesk-backend"

cd "$(dirname "$0")/../.."   # repo root, e.g. /opt/echodesk/app
ROOT="$(pwd)"
echo "=== EchoDesk restart ==="
echo "Root: $ROOT"

echo "--- git pull origin main ---"
git pull origin main
echo "Now at: $(git rev-parse --short HEAD) $(git log -1 --format='%s')"

# Reinstall backend deps only when requirements.txt actually changed in this pull.
if git diff --name-only 'HEAD@{1}' HEAD 2>/dev/null | grep -q '^backend/requirements.txt$'; then
  echo "--- requirements.txt changed: reinstalling backend deps ---"
  ./venv/bin/pip install -q -r backend/requirements.txt
else
  echo "--- backend deps unchanged (skipping pip install) ---"
fi

echo "--- restart $SERVICE ---"
sudo systemctl restart "$SERVICE"

# Verify it actually came back up (guards against the "stale process" trap).
sleep 2
systemctl show "$SERVICE" -p ActiveState -p SubState -p ActiveEnterTimestamp
if systemctl is-active --quiet "$SERVICE"; then
  echo "OK: $SERVICE is active and running the new code."
else
  echo "ERROR: $SERVICE is not active. Recent logs:"
  journalctl -u "$SERVICE" -n 30 --no-pager || true
  exit 1
fi
echo "=== Done ==="
