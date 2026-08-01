#!/usr/bin/env bash
# Bootstrap the Home Assistant host on a Raspberry Pi (Debian).
# Idempotent: safe to re-run after a config change or a dongle swap.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

log() { echo "==> $*"; }

# --- Docker -----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
  log "Docker installed. Log out and back in for the 'docker' group to apply."
else
  log "Docker already installed ($(docker --version))"
fi

# --- .env -------------------------------------------------------------------
if [ ! -f .env ]; then
  DETECTED="$(ls /dev/serial/by-id/*MG21* /dev/serial/by-id/*Zigbee* 2>/dev/null | head -1 || true)"
  if [ -z "$DETECTED" ]; then
    DETECTED="$(ls /dev/serial/by-id/* 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$DETECTED" ]; then
    cp .env.example .env
    echo "No serial device found under /dev/serial/by-id/." >&2
    echo "Plug in the Zigbee dongle, set ZIGBEE_DEVICE in .env, then re-run." >&2
    exit 1
  fi
  sed "s#^ZIGBEE_DEVICE=.*#ZIGBEE_DEVICE=$DETECTED#" .env.example > .env
  log "Created .env, detected dongle at $DETECTED"
else
  log ".env already present, leaving it alone"
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if [ ! -e "$ZIGBEE_DEVICE" ]; then
  echo "ZIGBEE_DEVICE=$ZIGBEE_DEVICE does not exist. Is the dongle plugged in?" >&2
  exit 1
fi

# --- Pi-hole password --------------------------------------------------------
# Covers both a fresh .env (copied from .env.example, PIHOLE_PASSWORD=changeme)
# and an existing pre-Pi-hole .env from an earlier setup, where the line is
# absent entirely: either way, land on a real random password, never a default.
if [ -z "${PIHOLE_PASSWORD:-}" ] || [ "${PIHOLE_PASSWORD:-}" = "changeme" ]; then
  GENERATED_PASSWORD="$(openssl rand -base64 18)"
  if grep -q '^PIHOLE_PASSWORD=' .env; then
    sed -i "s#^PIHOLE_PASSWORD=.*#PIHOLE_PASSWORD=$GENERATED_PASSWORD#" .env
  else
    echo "PIHOLE_PASSWORD=$GENERATED_PASSWORD" >> .env
  fi
  log "Generated a Pi-hole admin password (shown once): $GENERATED_PASSWORD"
  export PIHOLE_PASSWORD="$GENERATED_PASSWORD"
fi

# --- Zigbee reconnection watchdog ------------------------------------------
# ZHA (bellows) does not recover on its own when the coordinator disappears and
# comes back: the container has to be restarted. udev fires the unit below when
# the dongle re-enumerates.
log "Installing Zigbee reconnection watchdog (udev + systemd)..."
# Key the rule on the dongle's own USB serial number, not on the ttyUSBn name:
# the latter depends on enumeration order and would match the wrong device as
# soon as a second USB-serial adapter is plugged in.
DONGLE_SERIAL="$(udevadm info -q property -n "$ZIGBEE_DEVICE" | sed -n 's/^ID_SERIAL_SHORT=//p')"
if [ -z "$DONGLE_SERIAL" ]; then
  echo "Could not read ID_SERIAL_SHORT for $ZIGBEE_DEVICE" >&2
  exit 1
fi
log "Dongle serial: $DONGLE_SERIAL"

sudo tee /etc/systemd/system/zigbee-recover.service > /dev/null <<EOF
[Unit]
Description=Restart Home Assistant after the Zigbee coordinator re-enumerates
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$REPO_DIR/scripts/zigbee-recover.sh
EOF

sudo tee /etc/udev/rules.d/99-zigbee-recover.rules > /dev/null <<EOF
# Sonoff Zigbee coordinator (Silicon Labs CP210x), matched by USB serial number.
# On re-plug, restart Home Assistant: ZHA/bellows does not reconnect on its own.
ACTION=="add", SUBSYSTEM=="tty", ENV{ID_SERIAL_SHORT}=="$DONGLE_SERIAL", TAG+="systemd", ENV{SYSTEMD_WANTS}="zigbee-recover.service"
EOF

sudo systemctl daemon-reload
sudo udevadm control --reload-rules

# --- Start ------------------------------------------------------------------
log "Starting Home Assistant and Pi-hole..."
docker compose up -d

PI_IP="$(hostname -I | awk '{print $1}')"
log "Done. Home Assistant: http://$PI_IP:8123 — Pi-hole admin: http://$PI_IP/admin"
