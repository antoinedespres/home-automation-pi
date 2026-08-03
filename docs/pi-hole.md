*[Lire en français](pi-hole.fr.md)*

# Pi-hole (DNS-level ad & tracker blocking)

Pi-hole runs as a second container alongside Home Assistant, acting as a DNS server that blocks ads and trackers for any device configured to use it — including over Tailscale, when away from home.

## Setup

`scripts/setup.sh` generates a random admin password on first run (printed once to the terminal — write it down). If you set up `.env` by hand instead, replace the `PIHOLE_PASSWORD=changeme` placeholder in `.env.example` before starting.

```
docker compose up -d
```

Admin UI: `http://192.168.1.146/admin` (or `http://<pi-tailscale-ip>/admin` from outside the LAN).

## Making devices use it

Pi-hole only blocks queries that are actually sent to it. Two ways to point traffic at it:

1. **Router-wide (recommended)** — in the router's DHCP settings, set the DNS server handed out to clients to the Pi's LAN IP (`192.168.1.146`). Every device on the network picks it up on its next DHCP renewal (or after a reboot / Wi-Fi toggle). This is the one-time change that gives you the "ad-free everywhere on the LAN" effect.
2. **Per-device** — override the DNS server in a single device's network settings, without touching the router.

### Making it follow you over Tailscale

Since the Pi is already the tailnet's exit node, you can get the same blocking on mobile data too: in the [Tailscale admin console](https://login.tailscale.com/admin/dns) → **DNS**, add the Pi's tailnet IP (`100.123.220.105`) as a **Global nameserver** and enable **Override local DNS**. Every device on the tailnet then routes DNS through Pi-hole regardless of which network it's on.

## Toggling

Several levels, from quickest to most permanent:

- **Pause blocking, keep the container running** — useful when troubleshooting whether Pi-hole broke a site:
  ```
  docker exec pihole pihole disable        # indefinite
  docker exec pihole pihole disable 300    # 5 minutes, re-enables itself
  docker exec pihole pihole enable
  ```
  Same toggle as the button at the top of the admin dashboard.
- **Stop/start the container** (DNS resolution for anyone still pointed at the Pi breaks until it's back):
  ```
  docker compose stop pihole
  docker compose up -d pihole
  ```
- **Undo network-wide** — revert the router's DHCP DNS setting to its default (or to `1.1.1.1` / `8.8.8.8`), and revert the Tailscale global nameserver if you set one. Devices pick up the change on their next DHCP renewal / Tailscale re-sync.

## Updating

Covered by the same routine as Home Assistant — `docker compose pull && docker compose up -d` updates both containers. See [operations.md](operations.md).
