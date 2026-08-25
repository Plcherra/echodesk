#!/bin/bash
# One-time setup: let the deploy user restart the EchoDesk backend without a sudo password.
# Run as root on the VPS (e.g. via the sudo-capable user):
#   sudo bash /opt/echodesk/app/deploy/scripts/setup-restart-sudoers.sh
#
# After this, `vps_restart.sh` runs end-to-end as the echodesk user with no password prompt.

set -e
DEPLOY_USER="${1:-echodesk}"
SERVICE="echodesk-backend"
POCKET_SERVICE="pocket-tts"
SUDOERS_FILE="/etc/sudoers.d/echodesk-restart"

# Match the exact binary path sudo will resolve, so the NOPASSWD rule applies.
SYSTEMCTL="$(command -v systemctl || echo /usr/bin/systemctl)"

echo "Granting $DEPLOY_USER passwordless restart of $SERVICE and $POCKET_SERVICE via $SYSTEMCTL ..."

cat > "$SUDOERS_FILE" << EOF
# EchoDesk: allow $DEPLOY_USER to control backend + pocket sidecar without a password
$DEPLOY_USER ALL=(ALL) NOPASSWD: $SYSTEMCTL restart $SERVICE
$DEPLOY_USER ALL=(ALL) NOPASSWD: $SYSTEMCTL start $SERVICE
$DEPLOY_USER ALL=(ALL) NOPASSWD: $SYSTEMCTL stop $SERVICE
$DEPLOY_USER ALL=(ALL) NOPASSWD: $SYSTEMCTL restart $POCKET_SERVICE
$DEPLOY_USER ALL=(ALL) NOPASSWD: $SYSTEMCTL start $POCKET_SERVICE
$DEPLOY_USER ALL=(ALL) NOPASSWD: $SYSTEMCTL stop $POCKET_SERVICE
EOF

chmod 440 "$SUDOERS_FILE"
visudo -c -f "$SUDOERS_FILE"  # Validate syntax; aborts on error

echo "Done. $DEPLOY_USER can now run: sudo systemctl restart $SERVICE (no password)."
