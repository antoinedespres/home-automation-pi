#!/usr/bin/env bash
# Restart Home Assistant once the Zigbee coordinator is back on the bus.
# Triggered by udev (see /etc/udev/rules.d/99-zigbee-recover.rules), or by hand.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$REPO_DIR/.env"
set +a

log() { logger -t zigbee-recover "$*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Recovery triggered"

# udev fires as soon as the device node appears; give the CP210x driver a moment
# to finish setting the port up before handing it to the container.
for _ in $(seq 1 15); do
  [ -e "$ZIGBEE_DEVICE" ] && break
  sleep 1
done

if [ ! -e "$ZIGBEE_DEVICE" ]; then
  log "ZIGBEE_DEVICE=$ZIGBEE_DEVICE still absent, aborting"
  exit 1
fi
sleep 2

log "Restarting the homeassistant container"
docker compose -f "$REPO_DIR/docker-compose.yml" --project-directory "$REPO_DIR" restart homeassistant
log "Recovery sequence completed"
