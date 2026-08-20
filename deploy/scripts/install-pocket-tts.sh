#!/bin/bash
# Move the Phase 0 spike from rex's home into EchoDesk ownership and install systemd.
# Run on the VPS as echodesk (has sudo):
#   sudo bash /opt/echodesk/app/deploy/scripts/install-pocket-tts.sh
# Or, before the repo is updated:
#   sudo bash ./install-pocket-tts.sh

set -euo pipefail

SPIKE="${POCKET_SPIKE_DIR:-/home/rex/pocket-tts-spike}"
DEST="${POCKET_DEST_DIR:-/opt/echodesk/pocket-tts}"
VOICES="${POCKET_TTS_VOICES_DIR:-/opt/echodesk/voices}"
APP="${ECHODESK_APP:-/opt/echodesk/app}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

echo "=== Stop any rex user sidecar so :8100 is free ==="
systemctl --user --machine=rex@ stop pocket-tts 2>/dev/null || true
systemctl --user --machine=rex@ disable pocket-tts 2>/dev/null || true
systemctl stop pocket-tts 2>/dev/null || true

echo "=== Install tree under $DEST (echodesk) ==="
install -d -o echodesk -g echodesk "$DEST" "$VOICES" "$DEST/bin"

if [[ -d "$SPIKE/.venv" && ! -e "$DEST/.venv" ]]; then
  mv "$SPIKE/.venv" "$DEST/.venv"
fi
if [[ -f "$SPIKE/sidecar.py" ]]; then
  cp -a "$SPIKE/sidecar.py" "$DEST/sidecar.py"
fi
if [[ -f "$APP/deploy/pocket-tts/sidecar.py" ]]; then
  cp -a "$APP/deploy/pocket-tts/sidecar.py" "$DEST/sidecar.py"
fi
if [[ -x "$SPIKE/bin/ffmpeg" && ! -x "$DEST/bin/ffmpeg" ]]; then
  cp -a "$SPIKE/bin/ffmpeg" "$DEST/bin/ffmpeg"
fi
if [[ -f "$SPIKE/hf.env" ]]; then
  cp -a "$SPIKE/hf.env" "$DEST/hf.env"
  chmod 600 "$DEST/hf.env"
fi
if [[ -d "$SPIKE/voices" ]]; then
  find "$SPIKE/voices" -maxdepth 1 -type f -exec cp -a {} "$VOICES/" \;
fi

# Prefer repo unit once it exists.
UNIT_SRC="$APP/deploy/systemd/pocket-tts.service"
if [[ -f "$UNIT_SRC" ]]; then
  cp "$UNIT_SRC" /etc/systemd/system/pocket-tts.service
fi

chown -R echodesk:echodesk "$DEST" "$VOICES"
chmod 750 "$DEST" "$VOICES"

systemctl daemon-reload
systemctl enable --now pocket-tts
sleep 3
systemctl --no-pager --full status pocket-tts || true
curl -fsS http://127.0.0.1:8100/health || echo "health not ready yet (model still loading)"
echo "=== Pocket now runs as echodesk, not rex ==="
