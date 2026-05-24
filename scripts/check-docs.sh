#!/usr/bin/env bash
# Fail if docs/ contains any .md file not in the allowlist (canonical MVP docs only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Checking docs structure..."

ALLOWED=(
  "docs/core/SYSTEM_OVERVIEW.md"
  "docs/core/VOICE_PIPELINE.md"
  "docs/core/SMS_FLOW.md"
  "docs/core/ENV.md"
  "docs/core/ACCOUNT_ONBOARDING_PHASES.md"
  "docs/ops/RUNBOOK.md"
  "docs/README.md"
)

FAIL=0
while IFS= read -r -d '' file; do
  allowed=false
  for a in "${ALLOWED[@]}"; do
    if [[ "$file" == "$a" ]]; then
      allowed=true
      break
    fi
  done
  if [[ "$allowed" == false ]]; then
    echo "Unexpected doc file: $file"
    FAIL=1
  fi
done < <(find docs -type f -name "*.md" -print0 2>/dev/null || true)

if [[ $FAIL -eq 1 ]]; then
  echo "Docs structure invalid (update scripts/check-docs.sh allowlist only with intent)."
  exit 1
fi

echo "Docs structure OK (${#ALLOWED[@]} allowed paths)."
