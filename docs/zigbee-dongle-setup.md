*[Lire en français](zigbee-dongle-setup.fr.md)*

# Sonoff Zigbee dongle (EFR32MG21) on the Raspberry Pi

Reference for connecting the Sonoff Zigbee 3.0 USB dongle (Silicon Labs **EFR32MG21** chip, CP210x USB-serial bridge) to Home Assistant running in Docker on a Raspberry Pi.

## Firmware: no flashing needed

The dongle ships pre-flashed with an **EmberZNet NCP** firmware speaking **EZSP**, natively supported by Home Assistant's **ZHA** integration. Unlike the CC2652P-based "P" variant or older CC2531 dongles, there is no mandatory flashing step.

## Identifying the device

```
ls -l /dev/serial/by-id/
lsusb | grep -i "cp210x\|silicon"
```

Expect something like:

```
usb-SONOFF_SONOFF_Dongle_Lite_MG21_2a8828b54fa2ef11b848946661ce3355-if00-port0 -> ../../ttyUSB0
Bus 001 Device 004: ID 10c4:ea60 Silicon Labs CP210x UART Bridge
```

**Always reference the `/dev/serial/by-id/` path, never `/dev/ttyUSB0` directly.** The `by-id` name is derived from the dongle's serial number and is stable; `ttyUSBn` numbering depends on enumeration order and will shift the moment another USB-serial device is plugged in.

`scripts/setup.sh` auto-detects this and writes it to `.env` as `ZIGBEE_DEVICE`.

## USB passthrough

Docker on Linux passes the device node straight to the container:

```yaml
devices:
  - ${ZIGBEE_DEVICE}:/dev/ttyUSB0
```

The host path (whatever the `by-id` symlink resolves to) is exposed inside the container as a fixed `/dev/ttyUSB0`, which is what the ZHA config entry points at. That indirection means the ZHA config never has to change, even if the dongle enumerates differently on the host.

No `privileged: true` is needed — a `devices:` mapping is enough, and the container runs as root so the `root:dialout` `0660` permissions on the node are not an obstacle. The host user still wants to be in the `dialout` group for debugging the port by hand.

## Connecting ZHA

**Settings → Devices & services → Add integration → ZHA**, then:

- Manual port path configuration
- Radio type: **EZSP**
- Serial port path: `/dev/ttyUSB0`
- Port speed: `115200`, flow control: none

## After an unplug/replug

On Linux, udev re-creates the device node automatically, so unlike the macOS setup there's nothing to repair at the serial-port level. But ZHA's radio library (bellows) still does **not** reconnect to a coordinator that disappeared — the container has to be restarted.

That's automated by a udev rule installed by `scripts/setup.sh`:

```
# /etc/udev/rules.d/99-zigbee-recover.rules
ACTION=="add", SUBSYSTEM=="tty", ENV{ID_SERIAL_SHORT}=="<dongle-serial>", TAG+="systemd", ENV{SYSTEMD_WANTS}="zigbee-recover.service"
```

The rule matches the dongle's **USB serial number** (`udevadm info -q property -n /dev/ttyUSB0 | grep ID_SERIAL_SHORT`), not the `ttyUSBn` name — otherwise it would fire for whatever unrelated USB-serial adapter happened to land on `ttyUSB0`. `setup.sh` fills the serial in automatically.

which fires `zigbee-recover.service` → [`scripts/zigbee-recover.sh`](../scripts/zigbee-recover.sh), waiting for the node to settle before `docker compose restart homeassistant`.

This is event-driven, unlike the macOS LaunchAgent that had to poll every 30 seconds — udev knows the instant the device appears.

Check it worked:

```
journalctl -t zigbee-recover -n 20
docker compose logs --tail=50 homeassistant | grep -i zha
```

To trigger the recovery by hand: `./scripts/zigbee-recover.sh`.

## Pairing sensors

In the ZHA integration: **Add device**, then put the sensor into pairing mode (usually a long press on its reset button until the LED blinks — the exact gesture varies per model).

For a Sonoff SNZB-02P temperature sensor: hold reset ~5 s until the LED blinks, while "Add device" is active. It shows up within a few seconds.

## Testing signal quality before mounting a sensor

Before sticking a sensor to its final spot, leave it there a few minutes once paired, then check:

- **Link quality**: Settings → Devices & services → ZHA → ⚙️ Configure → **Visualization**. Shows the mesh graph with each link's LQI (0–255). Above ~130 is generally reliable; below that, or a link that appears and disappears, means the signal is too weak there.
- **Stability over time**: don't trust one instant reading. On the device's page, check values keep updating and the device doesn't flip to "unavailable".
- **USB 3.0 interference**: EFR32 dongles (2.4 GHz) are sensitive to USB 3.0 emissions — an issue Sonoff documents itself. On a Pi 4B, prefer the **USB 2.0 ports (the black ones)** over the blue USB 3.0 ones, and use a **USB extension cable** to move the dongle away from the Pi and from any USB 3.0 storage. This matters more on a Pi than it did on the Mac: the board is small, so the dongle ends up physically close to the Ethernet/USB 3.0 controller.
- The Sonoff S60ZBTPF smart plugs are mains-powered and act as **Zigbee routers**, extending mesh range for battery sensors near them.

## Battery devices and `last_seen`

Battery-powered end devices (SNZB-02P, SNZB-04P) sleep most of the time and only report on their own schedule or on an event (temperature change, door opening). A `last_seen` several hours old in `zigbee.db` is normal for them and does **not** mean the device is lost — mains-powered devices, by contrast, report continuously.
