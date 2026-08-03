#!/usr/bin/env bash
# Pull Home Assistant's automatic backups off the Pi, from a workstation.
# The Pi boots off an SD card — keeping a copy elsewhere is the whole point.
#
# Usage: ./scripts/pull-backup.sh [destination-dir]
set -euo pipefail

# Override PI_HOST/PI_DIR if your user or clone path differs from the defaults.
PI_HOST="${PI_HOST:-pi@raspberrypi.local}"
PI_DIR="${PI_DIR:-/home/pi/home-automation}"
DEST="${1:-$HOME/Backups/home-assistant}"

mkdir -p "$DEST"

echo "==> Pulling backups from $PI_HOST:$PI_DIR/config/backups/"
rsync -a --delete "$PI_HOST:$PI_DIR/config/backups/" "$DEST/backups/"

echo "==> Pulling the registries and YAML config (small, versionable state)"
rsync -a \
  --include='*.yaml' --include='.storage/' --include='.storage/**' \
  --exclude='*' \
  "$PI_HOST:$PI_DIR/config/" "$DEST/config-snapshot/"

echo "==> Done. Local copy:"
du -sh "$DEST"/* 2>/dev/null || true
