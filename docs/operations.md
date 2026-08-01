*[Lire en français](operations.fr.md)*

# Day-to-day operations

## Updating Home Assistant

```
cd ~/home-automation
docker compose pull
docker compose up -d
docker image prune -f      # reclaim the superseded image (~3 GB on disk)
```

Take a backup first (below). Downgrading is possible by pinning a version tag instead of `stable` in `docker-compose.yml`, but Home Assistant **migrates the recorder database schema forward on first start** and does not migrate back — a downgrade needs the pre-update backup restored.

## Backups

Home Assistant takes automatic backups into `config/backups/` (visible under Settings → System → Backups). They live on the same SD card as everything else, so they only protect against mistakes, not against the card dying.

Pull a copy to a workstation:

```
./scripts/pull-backup.sh                 # → ~/Backups/home-assistant
./scripts/pull-backup.sh /some/other/dir
```

Worth doing before every HA update, and on a schedule otherwise.

For a full offline copy of the state, with HA stopped:

```
docker compose stop homeassistant
sqlite3 config/home-assistant_v2.db "PRAGMA wal_checkpoint(TRUNCATE);"
tar czf ~/ha-config-$(date +%F).tar.gz config/
docker compose start homeassistant
```

## SD card longevity

The recorder database writes constantly, and SD cards wear out under sustained small writes. Options, roughly in order of effort:

- **Trim what gets recorded.** The single most effective change — most of the write volume is high-frequency sensors nobody queries historically. In `configuration.yaml`:

  ```yaml
  recorder:
    purge_keep_days: 30
    commit_interval: 30     # default 1s; batches writes
    exclude:
      entity_globs:
        - sensor.*_voltage
        - sensor.*_current
  ```

  The smart plugs' voltage/current sensors update every few seconds and dominate the database.

- **Move the whole thing to a USB SSD.** A Pi 4B can boot from USB; an SSD removes the wear concern and is noticeably faster for the database.

- **Move the recorder to an external database** (PostgreSQL/MariaDB, possibly on the VPS) via `recorder: db_url:`. More moving parts; only worth it if the history matters a lot.

Check current database size:

```
ls -lh config/home-assistant_v2.db
```

## Health checks

```
docker compose ps
docker compose logs --tail=100 homeassistant
journalctl -t zigbee-recover -n 20        # dongle reconnection events
vcgencmd measure_temp                     # Pi SoC temperature
df -h /                                   # SD card space
```

Home Assistant's own diagnostics live under Settings → System → Repairs and Settings → System → Logs.

## Restarting

```
docker compose restart homeassistant   # HA only
sudo reboot                            # whole Pi; HA comes back on its own
```

The container is `restart: unless-stopped` and the Docker service is enabled at boot, so Home Assistant starts automatically after a power cut. Nothing else needs to run at login — unlike the macOS setup, there is no LaunchAgent or user session involved.

## Bluetooth: two conditions, not one

The Pi has an onboard Bluetooth adapter (`hci0`) that `default_config` picks up — the macOS host had none, so this is specific to the Pi. If it isn't set up correctly, Home Assistant logs at every startup:

```
ERROR (MainThread) [habluetooth.manager] Missing required permissions for Bluetooth
management. Automatic adapter recovery is unavailable. Add NET_ADMIN and NET_RAW
capabilities to the container
PermissionError: Missing NET_ADMIN/NET_RAW capabilities for Bluetooth management
```

The message only names the capabilities, but **both** of these are required, and each alone is insufficient:

1. **`cap_add: [NET_ADMIN, NET_RAW]`** on the container (in `docker-compose.yml`).
2. **The adapter powered on at the host** — `hciconfig hci0` must report `UP RUNNING`.

Verified by elimination on this setup:

| Capabilities | `hci0` | Result |
|---|---|---|
| none | DOWN | `PermissionError` |
| `NET_ADMIN`+`NET_RAW` | DOWN | `PermissionError` |
| none | UP | `PermissionError` |
| `NET_ADMIN`+`NET_RAW` | UP | **clean** |

With the adapter down, the capability check fails in a way that surfaces as a permissions error rather than as "adapter unavailable", which is what makes this misleading — it's easy to conclude the capabilities aren't working when the real missing piece is the radio being powered off.

To make the adapter come up on its own after a reboot, `/etc/bluetooth/main.conf` has:

```
[Policy]
AutoEnable=true
```

Check the state with `hciconfig hci0` and `systemctl is-active bluetooth`. If the adapter is soft-blocked, `sudo rfkill unblock bluetooth`.

Note that under `network_mode: host`, `CAP_NET_ADMIN` lets the container reconfigure the host's network stack. That is a real privilege; it is granted here because Bluetooth works with it and the container is a trusted first-party image. If you never intend to use Bluetooth, dropping both capabilities and ignoring the discovered adapter in Settings → Devices & services is the lower-privilege alternative — the error is otherwise harmless and does not affect Zigbee.

## Secrets in `config/`

`config/` is git-ignored and must stay that way. It contains, in cleartext:

- `secrets.yaml`
- `.storage/auth` — user accounts, refresh tokens, long-lived access tokens
- `.storage/core.config_entries` — integration credentials, including the HACS GitHub token and mobile-app push tokens

If any of it has ever been committed or shared, rotate: the HACS token from GitHub's settings, and HA's own tokens from Settings → People / your profile → Long-lived access tokens.
