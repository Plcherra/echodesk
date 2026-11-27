#!/usr/bin/env bash
# Idempotent bootstrap for Cursor Cloud Agents (backend tests + validation scripts).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! python3 -m venv --help >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3.12-venv python3-pip
fi

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi

# shellcheck source=/dev/null
source .venv/bin/activate
python -m pip install --upgrade pip -q
pip install -q -r backend/requirements.txt

echo "Echodesk cloud install: Python venv at .venv (pytest: source .venv/bin/activate && pytest backend/tests -q)"
