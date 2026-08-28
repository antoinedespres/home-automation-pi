*[Read this in English](remote-access.md)*

# Accès distant via VPS + Tailscale + Caddy

Joindre Home Assistant depuis l'extérieur du réseau local (4G/5G, autre Wi-Fi) en utilisant un VPS existant comme point d'entrée public, **sans ouvrir aucun port sur la box**.

## Architecture

```
Mobile --HTTPS--> home.example.com --> VPS (Caddy, reverse proxy)
                                              |
                                       Tunnel Tailscale (WireGuard)
                                              |
                                   Raspberry Pi (Home Assistant :8123)
```

- **Tailscale** construit un maillage privé entre le Pi et le VPS, chacun avec une adresse `100.x.x.x` stable. La traversée de NAT est gérée pour vous — aucune redirection de port.
- **Caddy** sur le VPS termine le HTTPS (Let's Encrypt automatique) et proxyfie vers l'IP Tailscale du Pi sur le port 8123.
- **DNS** : un enregistrement `A` pour le sous-domaine pointe vers l'IP publique du VPS.

## Mise en place

1. **DNS** : enregistrement `A`, sous-domaine `home` → IP publique du VPS.

2. **Tailscale sur le Pi** :
   ```
   curl -fsSL https://tailscale.com/install.sh | sudo sh
   sudo tailscale up --hostname=pi-home-assistant
   ```
   La commande affiche une URL de connexion — l'ouvrir et s'authentifier avec le **même compte Tailscale** que le VPS, pour que les deux machines soient sur le même tailnet. Tailscale installe un service systemd et se reconnecte automatiquement après un redémarrage.

   Récupérer l'adresse obtenue avec `tailscale ip -4`.

3. **Tailscale sur le VPS**, si ce n'est pas déjà fait :
   ```
   curl -fsSL https://tailscale.com/install.sh | sudo sh
   sudo tailscale up --hostname=ovh-vps --ssh
   ```

4. **Caddy sur le VPS** — `/etc/caddy/Caddyfile` :
   ```
   home.example.com {
       reverse_proxy <ip-tailscale-du-pi>:8123
       log {
           output file /var/log/caddy/access.log {
               roll_size 10MiB
               roll_keep 5
           }
           format json
       }
   }
   ```
   Puis `sudo systemctl reload caddy`. Caddy demande et renouvelle le certificat lui-même.

5. **Déclarer le proxy comme fiable dans Home Assistant** — Paramètres > Système >
   Réseau, section « URL de Home Assistant » : activer l'option de reverse proxy et
   ajouter l'IP Tailscale du VPS à la liste des proxys de confiance. Aucun
   redémarrage nécessaire.

   > Depuis la version 2026.8, ce réglage vit uniquement dans l'interface, stocké
   > dans `config/.storage/http`. Un bloc `http:` dans `configuration.yaml` est
   > migré une fois puis ignoré, et HA signale une réparation tant qu'il n'est pas
   > retiré — il cessera complètement de fonctionner en 2027.2. Ne pas le remettre.

## Pourquoi le Pi a besoin d'une entrée `trusted_proxies` de moins que le Mac

L'installation macOS exigeait aussi `192.168.65.1`. Docker Desktop sur macOS exécute les conteneurs dans une VM, et les connexions entrantes vers un port publié y subissent un NAT — vu de l'intérieur du conteneur, la requête semblait donc venir de la passerelle interne de Docker Desktop, pas du VPS. Les deux adresses devaient être déclarées fiables.

Sur le Pi, le conteneur utilise `network_mode: host` : il n'y a ni couche NAT ni traduction de port publié, donc Home Assistant voit directement l'adresse Tailscale du VPS. Une seule entrée suffit.

Si `trusted_proxies` est mal réglé, le symptôme est un `400 Bad Request` avec `Received X-Forwarded-For header from an untrusted proxy` dans les journaux — l'adresse citée dans ce message est celle à ajouter.

## Basculer le tunnel du Mac vers le Pi

Seule l'étape 4 change : faire pointer `reverse_proxy` vers l'IP Tailscale du Pi au lieu de celle du Mac, puis recharger Caddy. Le domaine, le certificat et le DNS ne bougent pas : les applications mobiles continuent de fonctionner avec la même URL, sans reconfiguration.

Une fois la bascule confirmée, retirer la machine obsolète du tailnet depuis la console d'administration Tailscale.

## Sécurité et observabilité du VPS

Le VPS expose un point d'entrée HTTPS public et du SSH : il vaut la peine de surveiller les tentatives d'abus.

### SSH : conserver un port personnalisé à travers les mises à jour

Si SSH est déplacé hors du port 22, **ne pas** modifier `/usr/lib/systemd/system/ssh.socket` : ce fichier appartient au paquet `openssh-server` et est écrasé à la mise à jour, ce qui remet silencieusement le port à 22. Utiliser un fichier de surcharge :

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

La ligne `ListenStream=` vide efface d'abord les valeurs héritées ; IPv4 et IPv6 nécessitent chacune une ligne explicite car l'unité du paquet définit `BindIPv6Only=ipv6-only`.

### fail2ban

```
sudo apt install fail2ban
sudo fail2ban-client status sshd
```

La prison `sshd` par défaut fonctionne telle quelle sur Debian/Ubuntu.

### Journaux d'accès Caddy

```
sudo tail -f /var/log/caddy/access.log
```

Filtrer par statut ou par IP avec `jq`. Si le fichier de log est un jour recréé à la main, veiller à ce qu'il appartienne à `caddy:caddy` — un fichier appartenant à root fait échouer le rechargement de Caddy avec `permission denied`.

### Protection des connexions propre à Home Assistant

HA bannit les IP après plusieurs échecs d'authentification, par défaut (`ip_ban_enabled`) :

```
docker compose logs homeassistant | grep -i "invalid authentication"
docker exec homeassistant cat /config/ip_bans.yaml
```

### Ne pas exposer le Pi directement

Le port 8123 du Pi est en HTTP simple et n'est volontairement joignable que sur le réseau local et via Tailscale. Ne jamais le rediriger depuis la box : le chemin VPS + Caddy existe précisément pour que la seule surface publique soit un hôte durci disposant d'un vrai certificat.
