*[Read this in English](README.md)*

# Home Automation (Raspberry Pi)

Home Assistant sur Docker, sur un **Raspberry Pi 4B (4 Go, Debian 13 trixie, arm64)**, avec un dongle Zigbee Sonoff (ZBDongle-E / Dongle Lite, puce Silicon Labs EFR32MG21) et des capteurs Sonoff (température, ouverture de porte, prises connectées).

Remplace une installation macOS/Docker Desktop antérieure, [antoinedespres/home-automation](https://github.com/antoinedespres/home-automation), qui a servi de base à ce dépôt. Sous Linux, le dongle est transmis directement au conteneur : le pont TCP `ser2net` qu'imposait macOS **disparaît** — voir [docs/migration-from-macos.fr.md](docs/migration-from-macos.fr.md).

## Architecture

```
Capteurs Zigbee  --802.15.4-->  Dongle Sonoff (USB)
                                      |
                           /dev/serial/by-id/... (hôte)
                                      |  passthrough device Docker
                           /dev/ttyUSB0 (conteneur)
                                      |
                     Home Assistant (network_mode: host, port 8123)
                                      |
                         Raspberry Pi 4B - 192.168.1.146
```

## Prérequis

- Un Raspberry Pi sous Debian (Raspberry Pi OS Bookworm/Trixie ou Debian arm64)
- Le dongle Zigbee branché sur un port **USB 2.0** (les noirs — les ports USB 3.0 émettent des interférences 2,4 GHz qui dégradent la portée Zigbee)

## Démarrage

```
git clone <ce-repo> ~/home-automation
cd ~/home-automation
./scripts/setup.sh
```

`scripts/setup.sh` est idempotent et fait tout : installe Docker Engine s'il manque, génère `.env` (en détectant le dongle sous `/dev/serial/by-id/`), installe le watchdog de reconnexion Zigbee, et démarre le conteneur.

Puis ouvrir `http://<ip-du-pi>:8123`.

S'il s'agit d'une installation neuve et non d'une migration, suivre l'assistant de création de compte et ajouter l'intégration ZHA comme décrit dans [docs/zigbee-dongle-setup.fr.md](docs/zigbee-dongle-setup.fr.md).

## Pourquoi `ser2net` a disparu

Docker Desktop sur macOS exécute les conteneurs dans une VM sans passthrough USB, ce qui imposait un démon `ser2net` sur l'hôte pour exposer le port série du dongle en TCP (`socket://host.docker.internal:6638`). Docker sous Linux parle directement au noyau : le nœud de périphérique est passé au conteneur via une ligne `devices:`. Un démon de moins, un mode de panne de moins, et moins de latence vers le coordinateur.

Le périphérique est référencé par son chemin `/dev/serial/by-id/`, dérivé du numéro de série du dongle et donc stable au fil des redémarrages et rebranchements — contrairement à `/dev/ttyUSB0`, qui dépend de l'ordre d'énumération.

## Intégration Zigbee (ZHA)

Voir [docs/zigbee-dongle-setup.fr.md](docs/zigbee-dongle-setup.fr.md) : réglages radio, appairage des capteurs, et test de la qualité de liaison avant de fixer un capteur définitivement.

Un watchdog relance Home Assistant quand le dongle est débranché puis rebranché — la bibliothèque radio de ZHA ne se reconnecte pas d'elle-même. Sous Linux, c'est une **règle udev** qui déclenche une unité systemd (`scripts/zigbee-recover.sh`) sur l'événement `add` du périphérique, au lieu du LaunchAgent macOS qui devait interroger l'état toutes les 30 secondes.

## Accès depuis un mobile

Installer l'app officielle Home Assistant. Sur le même Wi-Fi, elle découvre automatiquement l'instance — c'est `network_mode: host` qui rend la découverte mDNS possible. Sinon, entrer `http://raspberrypi.local:8123` ou l'IP locale du Pi.

## Accès distant

Accessible depuis l'extérieur via un VPS faisant office de reverse proxy à travers un tunnel Tailscale — aucun port ouvert sur la box. Voir [docs/remote-access.fr.md](docs/remote-access.fr.md).

## Exploitation au quotidien

Mises à jour, sauvegardes, longévité de la carte SD et maintenance de la base : [docs/operations.fr.md](docs/operations.fr.md).

## Ce que ce dépôt contient — et ne contient pas

`config/` est **ignoré par git**. Ce dossier contient l'état d'exécution de Home Assistant : la base de l'historique, la base du réseau Zigbee, `secrets.yaml`, et `.storage/` avec les jetons d'authentification et clés d'API. Rien de tout cela n'a sa place dans un dépôt, même privé. Le dépôt porte la partie reproductible : fichier compose, scripts, documentation. Les sauvegardes de l'état sont gérées à part (voir [docs/operations.fr.md](docs/operations.fr.md)).
