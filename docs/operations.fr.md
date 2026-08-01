*[Read this in English](operations.md)*

# Exploitation au quotidien

## Mettre à jour Home Assistant

```
cd ~/home-automation
docker compose pull
docker compose up -d
docker image prune -f      # récupère l'espace de l'image remplacée (~3 Go sur disque)
```

Faire une sauvegarde d'abord (voir plus bas). Revenir en arrière est possible en épinglant une version au lieu de `stable` dans `docker-compose.yml`, mais Home Assistant **migre le schéma de la base du recorder vers l'avant au premier démarrage** et ne le migre pas en sens inverse : un retour arrière suppose de restaurer la sauvegarde d'avant la mise à jour.

## Sauvegardes

Home Assistant réalise des sauvegardes automatiques dans `config/backups/` (visibles sous Paramètres → Système → Sauvegardes). Elles résident sur la même carte SD que le reste : elles protègent donc des erreurs de manipulation, pas de la mort de la carte.

Rapatrier une copie sur un poste de travail :

```
./scripts/pull-backup.sh                 # → ~/Backups/home-assistant
./scripts/pull-backup.sh /autre/dossier
```

À faire avant chaque mise à jour de HA, et régulièrement le reste du temps.

Pour une copie hors ligne complète de l'état, HA arrêté :

```
docker compose stop homeassistant
sqlite3 config/home-assistant_v2.db "PRAGMA wal_checkpoint(TRUNCATE);"
tar czf ~/ha-config-$(date +%F).tar.gz config/
docker compose start homeassistant
```

## Longévité de la carte SD

La base du recorder écrit en permanence, et les cartes SD s'usent sous un régime soutenu de petites écritures. Options, grossièrement par effort croissant :

- **Réduire ce qui est enregistré.** Le changement le plus efficace — l'essentiel du volume d'écriture vient de capteurs à haute fréquence dont personne ne consulte l'historique. Dans `configuration.yaml` :

  ```yaml
  recorder:
    purge_keep_days: 30
    commit_interval: 30     # 1 s par défaut ; regroupe les écritures
    exclude:
      entity_globs:
        - sensor.*_voltage
        - sensor.*_current
  ```

  Les capteurs de tension/courant des prises connectées remontent une valeur toutes les quelques secondes et dominent la base.

- **Déplacer l'ensemble sur un SSD USB.** Un Pi 4B sait démarrer sur USB ; un SSD supprime le problème d'usure et est nettement plus rapide pour la base.

- **Déporter le recorder vers une base externe** (PostgreSQL/MariaDB, éventuellement sur le VPS) via `recorder: db_url:`. Plus de pièces mobiles ; ne vaut le coup que si l'historique compte beaucoup.

Taille actuelle de la base :

```
ls -lh config/home-assistant_v2.db
```

## Vérifications de santé

```
docker compose ps
docker compose logs --tail=100 homeassistant
journalctl -t zigbee-recover -n 20        # événements de reconnexion du dongle
vcgencmd measure_temp                     # température du SoC
df -h /                                   # espace sur la carte SD
```

Les diagnostics propres à Home Assistant sont sous Paramètres → Système → Réparations et Paramètres → Système → Journaux.

## Redémarrer

```
docker compose restart homeassistant   # HA seul
sudo reboot                            # tout le Pi ; HA revient tout seul
```

Le conteneur est en `restart: unless-stopped` et le service Docker est activé au démarrage : Home Assistant redémarre donc automatiquement après une coupure de courant. Rien d'autre n'a besoin de se lancer à l'ouverture de session — contrairement à l'installation macOS, aucun LaunchAgent ni session utilisateur n'entre en jeu.

## Secrets dans `config/`

`config/` est ignoré par git et doit le rester. Ce dossier contient, en clair :

- `secrets.yaml`
- `.storage/auth` — comptes utilisateurs, jetons de rafraîchissement, jetons d'accès longue durée
- `.storage/core.config_entries` — identifiants des intégrations, dont le jeton GitHub de HACS et les jetons de notification push des applications mobiles

Si l'un de ces éléments a déjà été commité ou partagé, il faut le renouveler : le jeton HACS depuis les paramètres GitHub, et les jetons propres à HA depuis Paramètres → Personnes / votre profil → Jetons d'accès longue durée.
