#!/usr/bin/env bash
# Install /usr/local/bin/echodesk-sync-landing + passwordless sudo for it.
# Run once on the VPS as root:
#   sudo bash deploy/scripts/install-landing-sudoers.sh [deploy_user]
#
# After this, CI can run deploy-landing.sh without an interactive password.

set -euo pipefail

DEPLOY_USER="${1:-echodesk}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="/usr/local/bin/echodesk-sync-landing"
SRC_DEFAULT="$ROOT/landing/dist"
TARGET="/var/www/echodesk-landing"

echo "Installing landing sync wrapper at $WRAPPER ..."
cat > "$WRAPPER" << EOF
#!/usr/bin/env bash
set -euo pipefail
SRC="\${1:-$SRC_DEFAULT}"
TARGET="$TARGET"
NGINX_USER="www-data"
if [ ! -d "\$SRC" ] || [ ! -f "\$SRC/index.html" ]; then
  echo "ERROR: invalid landing source: \$SRC" >&2
  exit 1
fi
mkdir -p "\$TARGET"
rsync -a --delete "\$SRC"/ "\$TARGET"/
if id "\$NGINX_USER" >/dev/null 2>&1; then
  chown -R "\$NGINX_USER:\$NGINX_USER" "\$TARGET"
fi
find "\$TARGET" -type d -exec chmod 755 {} \\;
find "\$TARGET" -type f -exec chmod 644 {} \\;
echo "Synced \$SRC -> \$TARGET"
EOF
chmod 755 "$WRAPPER"

SUDOERS_FILE="/etc/sudoers.d/echodesk-landing"
cat > "$SUDOERS_FILE" << EOF
$DEPLOY_USER ALL=(ALL) NOPASSWD: $WRAPPER
EOF
chmod 440 "$SUDOERS_FILE"
visudo -c -f "$SUDOERS_FILE"

echo "Done. $DEPLOY_USER can run: sudo $WRAPPER [$SRC_DEFAULT]"
