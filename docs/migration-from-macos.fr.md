*[Read this in English](migration-from-macos.md)*

# Migration de l'installation macOS vers le Raspberry Pi

Comment l'instance Home Assistant existante a été déplacée d'un Mac (Docker Desktop + `ser2net`) vers un Raspberry Pi 4B, en **préservant la configuration, l'historique et les appairages Zigbee** — aucun capteur n'a eu à être réappairé.

## Ce qu'il faut préserver, et où ça se trouve

| Quoi | Où | Pourquoi c'est important |
|---|---|---|
| Appairages Zigbee | `config/zigbee.db` + la NVRAM du dongle | Clé réseau, table des équipements. Sans ça, chaque capteur doit être réappairé à la main. |
| Registres entités/appareils, auth | `config/.storage/` | Identifiants d'entités, noms, zones, tableaux de bord, utilisateurs et jetons. |
| Historique / statistiques | `config/home-assistant_v2.db` | La base du recorder (~75 Mo ici). |
| Config YAML | `config/*.yaml` | `configuration.yaml`, automatisations, scripts, scènes, secrets. |

L'état d'appairage est réparti entre `zigbee.db` et la flash du coordinateur. Comme c'est le **même dongle physique** qui passe sur le Pi, les deux moitiés restent cohérentes et le maillage revient exactement tel quel.

## Procédure

### 1. Arrêter proprement Home Assistant sur le Mac

La base du recorder est du SQLite en mode WAL. La copier pendant que HA écrit donne un instantané incohérent.

```
docker compose stop homeassistant
```

Le conteneur peut recevoir un `SIGKILL` s'il ne s'arrête pas dans le délai imparti (code de sortie 137), ce qui laisse des données non validées dans le fichier `-wal`. Il faut les réintégrer dans la base principale et vérifier, pour les deux bases :

```
sqlite3 config/home-assistant_v2.db "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;"
sqlite3 config/zigbee.db           "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;"
```

Les deux doivent afficher `ok`. Après un checkpoint `TRUNCATE`, les fichiers `-wal` font 0 octet et peuvent être exclus de la copie.

Utile de relever un état de référence pour comparer ensuite :

```
sqlite3 config/zigbee.db "select count(*) from devices_v15;"     # appareils appairés, coordinateur inclus
sqlite3 config/home-assistant_v2.db "select count(*) from states;"
```

### 2. Copier l'état vers le Pi

```
rsync -a --stats \
  --exclude='.DS_Store' --exclude='home-assistant.log*' --exclude='.ha_run.lock' \
  --exclude='*.db-shm' --exclude='*.db-wal' --exclude='.storage/tmp*' \
  config/ pi:/home/antoine/home-automation/config/
```

Les `-shm`/`-wal` sont reconstruits par SQLite ; `.ha_run.lock` et les journaux sont du bruit propre à chaque hôte.

À noter : macOS fournit `openrsync`, qui refuse certaines options de GNU rsync (`--info=`, `--no-perms`). Les options ci-dessus sont le sous-ensemble portable.

Vérifier la copie plutôt que lui faire confiance : comparer `sha256sum` sur le Pi et `shasum -a 256` sur le Mac pour au moins `home-assistant_v2.db`, `zigbee.db` et `.storage/core.*`, puis relancer `PRAGMA integrity_check` sur le Pi.

### 3. Repointer ZHA vers le périphérique USB local

C'est le seul élément d'état réellement spécifique à l'hôte. L'entrée de configuration ZHA pointe encore vers le pont `ser2net` du Mac. Corriger `config/.storage/core.config_entries` :

```python
import json
p = ".storage/core.config_entries"
d = json.load(open(p))
for e in d["data"]["entries"]:
    if e["domain"] == "zha":
        e["data"]["device"]["path"] = "/dev/ttyUSB0"
json.dump(d, open(p, "w"), indent=2)
```

`socket://host.docker.internal:6638` → `/dev/ttyUSB0` (le chemin, dans le conteneur, vers lequel le fichier compose mappe le dongle). `radio_type: ezsp` et `baudrate: 115200` sont inchangés — même radio, même firmware.

> Modifier `.storage/` à la main n'est sûr qu'avec Home Assistant **arrêté** : il réécrit ces fichiers à l'extinction et écraserait la modification. Garder une copie `.bak`.

`flow_control` reste `null` : le connecteur `ser2net` de macOS utilisait `local`, c'est-à-dire aucun contrôle de flux matériel, et c'est le réglage avec lequel le dongle fonctionne depuis le début.

### 4. Ajuster `trusted_proxies`

L'installation macOS nécessitait `192.168.65.1` — la passerelle NAT interne de Docker Desktop, l'adresse depuis laquelle HA voyait réellement arriver les requêtes du reverse proxy. Avec `network_mode: host` sous Linux, il n'y a plus de couche NAT : HA voit l'adresse Tailscale réelle du VPS et cette entrée peut disparaître :

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - <ip-tailscale-du-vps>   # IP Tailscale du VPS qui fait tourner Caddy
```

### 5. Démarrer, et vérifier

```
./scripts/setup.sh
```

Puis vérifier que le coordinateur est bien remonté sur le vrai port série et que les appareils appairés sont tous de retour :

```
docker compose logs homeassistant | grep -i zha
```

### 6. Rediriger l'accès distant vers le Pi

Tailscale sur le Pi, puis mettre à jour le `Caddyfile` du VPS pour proxyfier vers l'IP Tailscale du Pi plutôt que celle du Mac. Voir [remote-access.fr.md](remote-access.fr.md).

### 7. Mettre le Mac hors service

Arrêter le conteneur, arrêter `ser2net`, et décharger le LaunchAgent du watchdog, pour que le Mac ne se batte pas avec le Pi pour le dongle (désormais absent) et ne réponde plus sur le port 8123 :

```
docker compose stop homeassistant
brew services stop ser2net
launchctl unload ~/Library/LaunchAgents/com.home-automation.zigbee-watchdog.plist
```

Laisser le dossier `config/` du Mac en place quelque temps : c'est un point de retour arrière connu comme fonctionnel.

## Retour arrière

Rebrancher le dongle sur le Mac, remettre le chemin `socket://` dans `.storage/core.config_entries` (ou restaurer le `.bak`), redémarrer `ser2net` et le conteneur. L'état du Mac n'est pas modifié par la migration ; seul l'historique enregistré sur le Pi depuis la bascule serait perdu.
