#!/usr/bin/env bash

set -euo pipefail

SNAPSHOT="${1:-}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK_ROOT="$SCRIPT_ROOT/fallback-scripts"
SOURCE_DIR="$FALLBACK_ROOT"
FILES=(
  "00-preflight.ps1"
  "00-preflight.sh"
  "00-setup.ps1"
  "00-setup.sh"
  "01-setup-wsl-ssh.ps1"
  "02-setup-coding-agents.ps1"
  "03-setup-pizza-ml-trainer.ps1"
  "03-setup-pizza-ml-trainer.sh"
  "launch.bat"
)

if [[ -n "$SNAPSHOT" ]]; then
  SOURCE_DIR="$FALLBACK_ROOT/snapshots/$SNAPSHOT"
fi

step() { echo -e "\n==> $*"; }
ok() { echo "  [OK] $*"; }

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "[FAIL] Fallback source not found: $SOURCE_DIR" >&2
  exit 1
fi

step "Restoring scripts from $SOURCE_DIR"
for file in "${FILES[@]}"; do
  if [[ ! -f "$SOURCE_DIR/$file" ]]; then
    echo "[FAIL] Missing fallback file: $SOURCE_DIR/$file" >&2
    exit 1
  fi
  cp "$SOURCE_DIR/$file" "$SCRIPT_ROOT/$file"
  ok "$file"
done

echo ""
echo "Restore complete."