*[Lire en français](migration-from-macos.fr.md)*

# Migrating from the macOS setup to the Raspberry Pi

How the existing Home Assistant instance was moved from a Mac (Docker Desktop + `ser2net`) to a Raspberry Pi 4B, **preserving configuration, history and Zigbee pairings** — no sensor had to be re-paired.

## What has to be preserved, and where it lives

| What | Where | Why it matters |
|---|---|---|
| Zigbee pairings | `config/zigbee.db` + the dongle's own NVRAM | Network key, device table. Lose it and every sensor must be re-paired by hand. |
| Entity/device registry, auth | `config/.storage/` | Entity IDs, names, areas, dashboards, logged-in users and long-lived tokens. |
| History / statistics | `config/home-assistant_v2.db` | The recorder database (~75 MB here). |
| YAML config | `config/*.yaml` | `configuration.yaml`, automations, scripts, scenes, secrets. |

The pairing state is split between `zigbee.db` and the coordinator's own flash. Because the **same physical dongle** moves to the Pi, both halves stay in sync and the mesh comes back exactly as it was.

## Procedure

### 1. Stop Home Assistant on the Mac, cleanly

The recorder database is SQLite in WAL mode. Copying it while HA is writing yields a torn snapshot.

```
docker compose stop homeassistant
```

The container can get `SIGKILL`ed if it doesn't stop within the timeout (exit code 137), which leaves uncommitted data in the `-wal` file. Fold it back into the main database and verify, for both databases:

```
sqlite3 config/home-assistant_v2.db "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;"
sqlite3 config/zigbee.db           "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;"
```

Both must print `ok`. After a `TRUNCATE` checkpoint the `-wal` files are 0 bytes and can be skipped in the copy.

Worth recording a baseline to compare against afterwards:

```
sqlite3 config/zigbee.db "select count(*) from devices_v15;"     # paired devices, incl. coordinator
sqlite3 config/home-assistant_v2.db "select count(*) from states;"
```

### 2. Copy the state to the Pi

```
rsync -a --stats \
  --exclude='.DS_Store' --exclude='home-assistant.log*' --exclude='.ha_run.lock' \
  --exclude='*.db-shm' --exclude='*.db-wal' --exclude='.storage/tmp*' \
  config/ pi:/home/antoine/home-automation/config/
```

`-shm`/`-wal` are rebuilt by SQLite; `.ha_run.lock` and the logs are per-host runtime noise.

Note: macOS ships `openrsync`, which rejects some GNU rsync flags (`--info=`, `--no-perms`). The flags above are the portable subset.

Verify the copy rather than trusting it — compare `sha256sum` on the Pi against `shasum -a 256` on the Mac for at least `home-assistant_v2.db`, `zigbee.db` and `.storage/core.*`, then re-run `PRAGMA integrity_check` on the Pi.

### 3. Repoint ZHA at the local USB device

This is the one piece of state that is genuinely host-specific. The ZHA config entry still points at the Mac's `ser2net` bridge. Patch `config/.storage/core.config_entries`:

```python
import json
p = ".storage/core.config_entries"
d = json.load(open(p))
for e in d["data"]["entries"]:
    if e["domain"] == "zha":
        e["data"]["device"]["path"] = "/dev/ttyUSB0"
json.dump(d, open(p, "w"), indent=2)
```

`socket://host.docker.internal:6638` → `/dev/ttyUSB0` (the in-container path the compose file maps the dongle to). `radio_type: ezsp` and `baudrate: 115200` are unchanged — same radio, same firmware.

> Editing `.storage/` by hand is only safe with Home Assistant **stopped**; it rewrites those files on shutdown and would overwrite the change. Keep a `.bak` copy.

`flow_control` stays `null`: the macOS `ser2net` connector used `local`, i.e. no hardware handshake, and that is the setting the dongle has been working with.

### 4. Adjust `trusted_proxies`

The macOS setup needed `192.168.65.1` — Docker Desktop's internal NAT gateway, which was the address HA actually saw incoming proxied requests coming from. With `network_mode: host` on Linux there is no NAT layer, so HA sees the VPS's real Tailscale address and that entry can go:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 100.87.166.49   # Tailscale IP of the VPS running Caddy
```

### 5. Start, and verify

```
./scripts/setup.sh
```

Then check that the coordinator came up on the real serial port and that the paired devices are all back:

```
docker compose logs homeassistant | grep -i zha
```

### 6. Point remote access at the Pi

Tailscale on the Pi, then update the VPS `Caddyfile` to reverse-proxy to the Pi's Tailscale IP instead of the Mac's. See [remote-access.md](remote-access.md).

### 7. Decommission the Mac

Stop the container, stop `ser2net`, and unload the watchdog LaunchAgent so the Mac doesn't fight the Pi for the (now absent) dongle or answer on port 8123:

```
docker compose stop homeassistant
brew services stop ser2net
launchctl unload ~/Library/LaunchAgents/com.home-automation.zigbee-watchdog.plist
```

Leave the Mac's `config/` directory in place for a while — it is a known-good rollback point.

## Rolling back

Plug the dongle back into the Mac, revert `.storage/core.config_entries` to the `socket://` path (or restore the `.bak`), start `ser2net` and the container. The Mac's state is untouched by the migration; only history recorded on the Pi since the cutover would be lost.
