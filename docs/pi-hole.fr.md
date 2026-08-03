*[Read this in English](pi-hole.md)*

# Pi-hole (blocage de pubs et traqueurs au niveau DNS)

Pi-hole tourne comme second conteneur aux côtés de Home Assistant, en tant que serveur DNS qui bloque les pubs et traqueurs pour tout appareil configuré pour l'utiliser — y compris via Tailscale, en dehors du domicile.

## Mise en place

`scripts/setup.sh` génère un mot de passe admin aléatoire au premier lancement (affiché une seule fois dans le terminal — à noter). En cas de création manuelle du `.env`, remplacer le placeholder `PIHOLE_PASSWORD=changeme` de `.env.example` avant de démarrer.

```
docker compose up -d
```

Interface admin : `http://192.168.1.146/admin` (ou `http://<ip-tailscale-du-pi>/admin` en dehors du réseau local).

## Faire utiliser Pi-hole par les appareils

Pi-hole ne bloque que les requêtes qui lui sont effectivement envoyées. Deux façons de router le trafic vers lui :

1. **Sur tout le réseau (recommandé)** — dans les paramètres DHCP du routeur, définir l'IP locale du Pi (`192.168.1.146`) comme serveur DNS distribué aux clients. Chaque appareil du réseau la récupère au prochain renouvellement DHCP (ou après un redémarrage / bascule Wi-Fi). C'est le changement à faire une seule fois pour obtenir l'effet « sans pub partout sur le réseau local ».
2. **Par appareil** — surcharger le serveur DNS dans les paramètres réseau d'un seul appareil, sans toucher au routeur.

### Le faire suivre en dehors du domicile via Tailscale

Le Pi étant déjà le nœud de sortie du tailnet, le même blocage peut s'appliquer aussi en données mobiles : dans la [console d'administration Tailscale](https://login.tailscale.com/admin/dns) → **DNS**, ajouter l'IP tailnet du Pi (`100.123.220.105`) comme **Global nameserver** et activer **Override local DNS**. Chaque appareil du tailnet route alors ses requêtes DNS via Pi-hole, quel que soit le réseau utilisé.

## Basculer on/off

Plusieurs niveaux, du plus rapide au plus permanent :

- **Suspendre le blocage sans arrêter le conteneur** — utile pour vérifier si Pi-hole casse un site :
  ```
  docker exec pihole pihole disable        # indéfiniment
  docker exec pihole pihole disable 300    # 5 minutes, se réactive tout seul
  docker exec pihole pihole enable
  ```
  Même bascule que le bouton en haut du tableau de bord admin.
- **Arrêter/démarrer le conteneur** (la résolution DNS casse pour qui pointe encore vers le Pi, jusqu'à son redémarrage) :
  ```
  docker compose stop pihole
  docker compose up -d pihole
  ```
- **Annuler à l'échelle du réseau** — remettre le DNS DHCP du routeur à sa valeur par défaut (ou à `1.1.1.1` / `8.8.8.8`), et retirer le nameserver global Tailscale si défini. Les appareils reprennent le changement à leur prochain renouvellement DHCP / resynchronisation Tailscale.

## Mise à jour

Couverte par la même routine que Home Assistant — `docker compose pull && docker compose up -d` met à jour les deux conteneurs. Voir [operations.fr.md](operations.fr.md).
