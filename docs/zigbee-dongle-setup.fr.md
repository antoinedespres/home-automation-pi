*[Read this in English](zigbee-dongle-setup.md)*

# Dongle Zigbee Sonoff (EFR32MG21) sur le Raspberry Pi

Référence pour connecter le dongle USB Sonoff Zigbee 3.0 (puce Silicon Labs **EFR32MG21**, pont USB-série CP210x) à Home Assistant sur Docker, sur un Raspberry Pi.

## Firmware : aucun flashage nécessaire

Le dongle est livré avec un firmware **EmberZNet NCP** parlant **EZSP**, nativement pris en charge par l'intégration **ZHA** de Home Assistant. Contrairement à la variante « P » (CC2652P) ou aux anciens CC2531, il n'y a pas d'étape de flashage obligatoire.

## Identifier le périphérique

```
ls -l /dev/serial/by-id/
lsusb | grep -i "cp210x\|silicon"
```

On attend quelque chose comme :

```
usb-SONOFF_SONOFF_Dongle_Lite_MG21_2a8828b54fa2ef11b848946661ce3355-if00-port0 -> ../../ttyUSB0
Bus 001 Device 004: ID 10c4:ea60 Silicon Labs CP210x UART Bridge
```

**Toujours référencer le chemin `/dev/serial/by-id/`, jamais `/dev/ttyUSB0` directement.** Le nom `by-id` est dérivé du numéro de série du dongle et reste stable ; la numérotation `ttyUSBn` dépend de l'ordre d'énumération et changera dès qu'un autre périphérique USB-série sera branché.

`scripts/setup.sh` détecte ce chemin automatiquement et l'écrit dans `.env` sous `ZIGBEE_DEVICE`.

## Passthrough USB

Docker sous Linux transmet directement le nœud de périphérique au conteneur :

```yaml
devices:
  - ${ZIGBEE_DEVICE}:/dev/ttyUSB0
```

Le chemin côté hôte (ce vers quoi pointe le lien `by-id`) est exposé dans le conteneur sous un `/dev/ttyUSB0` fixe, qui est ce que vise l'entrée de configuration ZHA. Cette indirection fait que la configuration ZHA n'a jamais à changer, même si le dongle s'énumère différemment sur l'hôte.

Pas besoin de `privileged: true` — un mappage `devices:` suffit, et le conteneur tournant en root, les permissions `root:dialout` `0660` du nœud ne posent pas de problème. L'utilisateur de l'hôte a quand même intérêt à être dans le groupe `dialout` pour déboguer le port à la main.

## Connecter ZHA

**Paramètres → Appareils et services → Ajouter une intégration → ZHA**, puis :

- Configuration manuelle du chemin du port
- Type de radio : **EZSP**
- Chemin du port série : `/dev/ttyUSB0`
- Vitesse : `115200`, contrôle de flux : aucun

## Après un débranchement/rebranchement

Sous Linux, udev recrée automatiquement le nœud de périphérique : contrairement à l'installation macOS, il n'y a rien à réparer au niveau du port série. Mais la bibliothèque radio de ZHA (bellows) ne se reconnecte **toujours pas** à un coordinateur qui a disparu — il faut redémarrer le conteneur.

C'est automatisé par une règle udev installée par `scripts/setup.sh` :

```
# /etc/udev/rules.d/99-zigbee-recover.rules
ACTION=="add", SUBSYSTEM=="tty", ENV{ID_SERIAL_SHORT}=="<serie-du-dongle>", TAG+="systemd", ENV{SYSTEMD_WANTS}="zigbee-recover.service"
```

La règle se cale sur le **numéro de série USB** du dongle (`udevadm info -q property -n /dev/ttyUSB0 | grep ID_SERIAL_SHORT`), et non sur le nom `ttyUSBn` — sinon elle se déclencherait pour n'importe quel adaptateur USB-série sans rapport qui se retrouverait sur `ttyUSB0`. `setup.sh` renseigne le numéro de série automatiquement.

qui déclenche `zigbee-recover.service` → [`scripts/zigbee-recover.sh`](../scripts/zigbee-recover.sh), lequel attend que le nœud se stabilise avant de faire `docker compose restart homeassistant`.

C'est événementiel, contrairement au LaunchAgent macOS qui devait sonder toutes les 30 secondes — udev sait à l'instant précis où le périphérique apparaît.

Vérifier que ça a fonctionné :

```
journalctl -t zigbee-recover -n 20
docker compose logs --tail=50 homeassistant | grep -i zha
```

Pour déclencher la reprise à la main : `./scripts/zigbee-recover.sh`.

## Appairer des capteurs

Dans l'intégration ZHA : **Ajouter un appareil**, puis mettre le capteur en mode appairage (généralement un appui long sur son bouton reset jusqu'à ce que la LED clignote — le geste exact varie selon le modèle).

Pour un capteur de température Sonoff SNZB-02P : maintenir reset ~5 s jusqu'au clignotement, pendant que « Ajouter un appareil » est actif. Il apparaît en quelques secondes.

## Tester la qualité du signal avant de fixer un capteur

Avant de coller un capteur à son emplacement définitif, l'y laisser quelques minutes une fois appairé, puis vérifier :

- **Qualité de liaison** : Paramètres → Appareils et services → ZHA → ⚙️ Configurer → **Visualisation**. Affiche le graphe du maillage avec le LQI de chaque lien (0–255). Au-dessus de ~130, la liaison est généralement fiable ; en dessous, ou si le lien apparaît et disparaît, le signal est trop faible à cet endroit.
- **Stabilité dans le temps** : ne pas se fier à une mesure instantanée. Sur la page de l'appareil, vérifier que les valeurs continuent de se mettre à jour et que l'appareil ne bascule pas en « indisponible ».
- **Interférences USB 3.0** : les dongles EFR32 (2,4 GHz) sont sensibles aux émissions USB 3.0 — un problème que Sonoff documente lui-même. Sur un Pi 4B, préférer les **ports USB 2.0 (les noirs)** aux bleus USB 3.0, et utiliser une **rallonge USB** pour éloigner le dongle du Pi et de tout stockage USB 3.0. Cela compte davantage que sur le Mac : la carte est petite, le dongle se retrouve donc physiquement très près du contrôleur Ethernet/USB 3.0.
- Les prises connectées Sonoff S60ZBTPF sont alimentées sur secteur et font office de **routeurs Zigbee**, étendant la portée du maillage pour les capteurs sur pile situés à proximité.

## Appareils sur pile et `last_seen`

Les équipements terminaux sur pile (SNZB-02P, SNZB-04P) dorment la plupart du temps et ne se manifestent que selon leur propre rythme ou sur événement (variation de température, ouverture de porte). Un `last_seen` vieux de plusieurs heures dans `zigbee.db` est normal pour eux et ne signifie **pas** que l'appareil est perdu — les appareils sur secteur, eux, remontent des valeurs en continu.
