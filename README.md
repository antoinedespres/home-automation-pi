*[Lire en français](README.fr.md)*

# Home Automation (Raspberry Pi)

Home Assistant running in Docker on a **Raspberry Pi 4B (4 GB, Debian 13 trixie, arm64)**, with a Sonoff Zigbee dongle (ZBDongle-E / Dongle Lite, Silicon Labs EFR32MG21) and Sonoff sensors (temperature, door/window, smart plugs).

This replaces an earlier macOS/Docker Desktop setup, [antoinedespres/home-automation](https://github.com/antoinedespres/home-automation), which this repo used as groundwork. On Linux the dongle is passed straight through to the container, so the `ser2net` TCP bridge that macOS required is **gone** — see [docs/migration-from-macos.md](docs/migration-from-macos.md).

## Architecture

```
Zigbee sensors  --802.15.4-->  Sonoff dongle (USB)
                                     |
                          /dev/serial/by-id/... (host)
                                     |  docker device passthrough
                          /dev/ttyUSB0 (container)
                                     |
                    Home Assistant (network_mode: host, port 8123)
                                     |
                        Raspberry Pi 4B - 192.168.1.146
```

## Prerequisites

- Raspberry Pi running Debian (Raspberry Pi OS Bookworm/Trixie or Debian arm64)
- The Zigbee dongle plugged into a **USB 2.0** port (the black ones — USB 3.0 ports emit 2.4 GHz interference that degrades Zigbee range)

## Getting started

```
git clone <this-repo> ~/home-automation
cd ~/home-automation
./scripts/setup.sh
```

`scripts/setup.sh` is idempotent and does everything: installs Docker Engine if missing, generates `.env` (auto-detecting the dongle under `/dev/serial/by-id/`), installs the Zigbee reconnection watchdog, and starts the container.

Then open `http://<pi-ip>:8123`.

If this is a fresh install rather than a migration, follow the account-creation wizard and add the ZHA integration as described in [docs/zigbee-dongle-setup.md](docs/zigbee-dongle-setup.md).

## Why no `ser2net` any more

Docker Desktop on macOS runs containers inside a VM with no USB passthrough, which forced a `ser2net` daemon on the host to expose the dongle's serial port over TCP (`socket://host.docker.internal:6638`). Docker on Linux talks to the kernel directly, so the device node is handed to the container with a one-line `devices:` mapping. One fewer daemon, one fewer failure mode, and lower latency to the coordinator.

The device is referenced by its `/dev/serial/by-id/` path, which is derived from the dongle's serial number and stays stable across reboots and re-plugs — unlike `/dev/ttyUSB0`, which depends on enumeration order.

## Zigbee integration (ZHA)

See [docs/zigbee-dongle-setup.md](docs/zigbee-dongle-setup.md) for radio settings, pairing sensors, and testing link quality before mounting a sensor permanently.

A watchdog restarts Home Assistant when the dongle is unplugged and replugged — ZHA's radio library does not reconnect on its own. On Linux this is a **udev rule** firing a systemd unit (`scripts/zigbee-recover.sh`) on the device's `add` event, rather than the 30-second polling LaunchAgent the macOS setup needed.

## Access from mobile

Install the official Home Assistant app. On the same Wi-Fi it should auto-discover the instance — `network_mode: host` is what makes mDNS discovery work. Otherwise enter `http://raspberrypi.local:8123` or the Pi's LAN IP.

## Remote access

Reachable from outside the home network through a VPS acting as a reverse proxy over a Tailscale tunnel — no port opened on the router. See [docs/remote-access.md](docs/remote-access.md).

## Day-to-day operations

Updates, backups, SD-card longevity and database maintenance: [docs/operations.md](docs/operations.md).

## What is and isn't in this repo

`config/` is **git-ignored**. It holds Home Assistant's runtime state — the recorder database, the Zigbee network database, `secrets.yaml`, and `.storage/` with auth tokens and API keys. None of that belongs in a repo, private or not. The repo carries the reproducible parts: compose file, scripts, docs. Backups of the state are handled separately (see [docs/operations.md](docs/operations.md)).
