*[Lire en français](remote-access.fr.md)*

# Remote access via VPS + Tailscale + Caddy

Reaching Home Assistant from outside the home network (cellular data, another Wi-Fi) using an existing VPS as the public entry point, with **no port opened on the home router**.

## Architecture

```
Mobile --HTTPS--> home.example.com --> VPS (Caddy, reverse proxy)
                                              |
                                       Tailscale tunnel (WireGuard)
                                              |
                                   Raspberry Pi (Home Assistant :8123)
```

- **Tailscale** builds a private mesh between the Pi and the VPS, each with a stable `100.x.x.x` address. NAT traversal is handled for you — no port forwarding.
- **Caddy** on the VPS terminates HTTPS (automatic Let's Encrypt) and reverse-proxies to the Pi's Tailscale IP on port 8123.
- **DNS**: an `A` record for the subdomain points at the VPS's public IP.

## Setup

1. **DNS**: `A` record, subdomain `home` → VPS public IP.

2. **Tailscale on the Pi**:
   ```
   curl -fsSL https://tailscale.com/install.sh | sudo sh
   sudo tailscale up --hostname=pi-home-assistant
   ```
   This prints a login URL — open it and authenticate with the **same Tailscale account** the VPS uses, so both machines land on the same tailnet. Tailscale installs a systemd service and reconnects automatically after a reboot.

   Get the resulting address with `tailscale ip -4`.

3. **Tailscale on the VPS**, if not already done:
   ```
   curl -fsSL https://tailscale.com/install.sh | sudo sh
   sudo tailscale up --hostname=ovh-vps --ssh
   ```

4. **Caddy on the VPS** — `/etc/caddy/Caddyfile`:
   ```
   home.example.com {
       reverse_proxy <pi-tailscale-ip>:8123
       log {
           output file /var/log/caddy/access.log {
               roll_size 10MiB
               roll_keep 5
           }
           format json
       }
   }
   ```
   Then `sudo systemctl reload caddy`. Caddy requests and renews the certificate itself.

5. **Trust the proxy in Home Assistant** — `config/configuration.yaml`:
   ```yaml
   http:
     use_x_forwarded_for: true
     trusted_proxies:
       - <vps-tailscale-ip>
   ```
   Then `docker compose restart homeassistant`.

## Why the Pi needs one fewer `trusted_proxies` entry than the Mac did

The macOS setup also required `192.168.65.1`. Docker Desktop on macOS runs containers inside a VM, and inbound connections to a published port get NAT'd by it — so from inside the container the request appeared to come from Docker Desktop's internal gateway, not from the VPS. Both addresses had to be trusted.

On the Pi the container uses `network_mode: host`: there is no NAT layer and no published-port translation, so Home Assistant sees the VPS's Tailscale address directly. Only that one entry is needed.

If `trusted_proxies` is wrong, the symptom is a `400 Bad Request` with `Received X-Forwarded-For header from an untrusted proxy` in the logs — the address named in that message is the one to add.

## Migrating the tunnel from the Mac to the Pi

Only step 4 changes: point `reverse_proxy` at the Pi's Tailscale IP instead of the Mac's, and reload Caddy. The domain, certificate and DNS are untouched, so the mobile apps keep working against the same URL with no reconfiguration.

Once confirmed, remove the stale machine from the tailnet in the Tailscale admin console.

## VPS security & observability

The VPS has a public HTTPS entry point and SSH, so it's worth watching for abuse.

### SSH: keep a custom port through package upgrades

If SSH is moved off port 22, **don't** edit `/usr/lib/systemd/system/ssh.socket` — that file belongs to `openssh-server` and gets overwritten on upgrade, silently resetting the port to 22. Use a drop-in override:

```
sudo mkdir -p /etc/systemd/system/ssh.socket.d
sudo tee /etc/systemd/system/ssh.socket.d/override.conf > /dev/null <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:<port>
ListenStream=[::]:<port>
EOF
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
```

The empty `ListenStream=` clears the inherited defaults first; both IPv4 and IPv6 need explicit lines because the package's unit sets `BindIPv6Only=ipv6-only`.

### fail2ban

```
sudo apt install fail2ban
sudo fail2ban-client status sshd
```

The default `sshd` jail works out of the box on Debian/Ubuntu.

### Caddy access logs

```
sudo tail -f /var/log/caddy/access.log
```

Filter by status or IP with `jq`. If the log file is ever recreated by hand, make sure it's owned by `caddy:caddy` — a root-owned file makes Caddy fail to reload with `permission denied`.

### Home Assistant's own login protection

HA bans IPs after repeated failed logins by default (`ip_ban_enabled`):

```
docker compose logs homeassistant | grep -i "invalid authentication"
docker exec homeassistant cat /config/ip_bans.yaml
```

### Don't expose the Pi directly

The Pi's port 8123 is plain HTTP and is deliberately only reachable on the LAN and over Tailscale. Never port-forward it on the router — the VPS + Caddy path exists precisely so that the only public surface is one hardened host with a proper certificate.
