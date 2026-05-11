#!/usr/bin/env bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK_ROOT="$SCRIPT_ROOT/fallback-scripts"
SNAPSHOTS_ROOT="$FALLBACK_ROOT/snapshots"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_DIR="$SNAPSHOTS_ROOT/$TIMESTAMP"
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

step() { echo -e "\n==> $*"; }
ok() { echo "  [OK] $*"; }

mkdir -p "$FALLBACK_ROOT" "$SNAPSHOTS_ROOT" "$SNAPSHOT_DIR"

step "Refreshing fallback-scripts root copy"
for file in "${FILES[@]}"; do
  cp "$SCRIPT_ROOT/$file" "$FALLBACK_ROOT/$file"
  ok "$file"
done

step "Saving dated snapshot to $SNAPSHOT_DIR"
for file in "${FILES[@]}"; do
  cp "$SCRIPT_ROOT/$file" "$SNAPSHOT_DIR/$file"
  ok "$file"
done

echo ""
echo "Saved fallback snapshot: $TIMESTAMP"