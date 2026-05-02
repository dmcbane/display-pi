# display-pi setup guide — fresh Pi to Sunday-morning ready

End-to-end procedure for turning a blank Raspberry Pi into a working
RTMP-driven kiosk display. Written for a single-Pi deployment receiving
an RTMP push from an ATEM Mini Pro; adapt the obvious bits if your
upstream is different.

> If you already have a working Pi and just want to push code changes,
> skip to [Day-to-day operations](#day-to-day-operations).

## What you need

### Hardware

| Item            | Pi 4 (recommended)                  | Pi 5 (also supported, see caveats) |
|-----------------|-------------------------------------|------------------------------------|
| Board           | Pi 4 Model B, 4 GB or 8 GB          | Pi 5, 4 GB or 8 GB                 |
| Power supply    | Official 5 V / 3 A USB-C            | Official 5 V / 5 A USB-C-PD        |
| Cooling         | Passive heatsink fine               | Active cooler strongly recommended |
| Storage         | 32 GB+ SD card (Samsung Pro / SanDisk Extreme — avoid no-name) |
| HDMI            | Micro-HDMI to HDMI cable, port 0    | Same                               |
| Network         | Ethernet preferred — RTMP video on Wi-Fi is unreliable |
| Capture (optional) | USB3 HDMI capture (e.g. MACROSILICON 345f:2131) on the workstation for visual debugging |

HDMI 0 is the **micro-HDMI port closer to the USB-C power input**. The
script and player are pinned to `vc4hdmi0` (HDMI 0); use HDMI 1 only if
you change the wiring documented in
`docs/dev-journal/2026-04-25-hdmi-audio-routing.md`.

### Software you'll be installing

- Raspberry Pi OS Lite (64-bit, Debian Bookworm) — the script assumes this exact base.
- The `display-pi` repo, cloned to your workstation.
- An RTMP source (an ATEM Mini Pro is what we use; OBS/ffmpeg also work).

### Network plan

Have an answer for these before you start:

- **Pi IP address** — DHCP is fine; reserve it on the router so it's stable.
- **RTMP allow-list** — the CIDR(s) permitted to push RTMP. Default is
  `192.168.0.0/16` and `10.0.0.0/8`; tighten to the ATEM's exact IP for
  better hygiene once it's stable.
- **Stream key** — defaults to `church242`. The ATEM and the kiosk
  must agree on this.

## Installation procedure

### 1. Flash the SD card

Use the [Raspberry Pi Imager](https://www.raspberrypi.com/software/).

- **OS:** Raspberry Pi OS Lite (64-bit), Bookworm.
- **Customise** (gear icon, do this — saves you a lot of first-boot pain):
  - Hostname: `displaypi` (or whatever you'll use in your SSH config).
  - Username: `rpi` (or pick another, but remember — this is the deploy user).
  - SSH: enable, prefer public-key auth (paste your workstation's `~/.ssh/id_*.pub`).
  - Wi-Fi: only fill in if you actually intend to use Wi-Fi. Ethernet is better for video.
  - Locale and timezone: set to your local timezone (logs will be more readable).
- Write, eject, insert into the Pi.

### 2. First boot

- Plug in **Ethernet**, **HDMI 0** (port closer to USB-C), and any USB
  peripherals you want.
- Plug in power. The Pi will expand the filesystem and reboot once.
- After ~90 seconds, find the IP. Easiest: check your router's DHCP
  lease table for the new `displaypi` entry. Or:

  ```sh
  # From the workstation, on the same LAN:
  ping displaypi.local           # mDNS, often works
  arp -a | grep -i 'b8:27:eb\|d8:3a:dd\|dc:a6:32\|2c:cf:67'   # Pi MAC OUIs
  ```

### 3. SSH config on the workstation

Add an alias so all the project's tooling (`make deploy`, `make logs`,
etc.) just works:

```sh
# ~/.ssh/config
Host displaypi
    HostName 192.168.0.106    # or displaypi.local, or whatever
    User rpi
    IdentityFile ~/.ssh/id_ed25519
```

Smoke test:

```sh
ssh displaypi true && echo OK
```

If you didn't pre-load your SSH key during imaging:

```sh
ssh-copy-id displaypi
```

### 4. Clone the repo onto the workstation

```sh
git clone git@github.com:dmcbane/display-pi.git
cd display-pi
```

### 5. Run setup-kiosk.sh on the Pi

The Pi needs a copy of the repo to run `setup-kiosk.sh`. Ship it over:

```sh
# From the workstation (in the display-pi/ checkout):
rsync -avz --exclude='.git/' . displaypi:~/display-pi/
ssh displaypi
cd ~/display-pi
```

Edit configuration if you need to (the defaults in `install/setup-kiosk.sh`
are sane for a 192.168.x.x LAN with a `church242` stream key — read the
top of the file and adjust if not):

```sh
$EDITOR install/setup-kiosk.sh
```

Run it:

```sh
bash install/setup-kiosk.sh
```

You'll be prompted for your sudo password once. The script is idempotent
— safe to re-run. It does, in order:

1. Installs packages (cage, mpv, nginx-rtmp, pipewire, watchdog, ...)
2. Creates the `kiosk` user
3. Enables `seatd`
4. Configures nginx with the RTMP module
5. Updates `/boot/firmware/config.txt` and `cmdline.txt` (watchdog,
   `vc4.force_hotplug=1`, `consoleblank=0`)
6. Generates a placeholder splash image at `/home/kiosk/splash.png`
7. Installs a minimal bootstrap player script (overwritten by the full
   one when you `make deploy`)
8. Installs the systemd user service
9. Configures the hardware watchdog
10. Configures PipeWire client.conf
10b. Installs the deploy sudoers whitelist (`/etc/sudoers.d/kiosk-deploy`)
11. Installs logrotate config
12. Installs the healthcheck cron stub

When it finishes, **reboot**:

```sh
sudo reboot
```

After ~30 s the Pi will come back into kiosk mode: a brief boot
diagnostics screen, then the splash image. From here on, you do not
need to log into the Pi for routine work.

### 6. First deploy from the workstation

Back on your workstation, in the `display-pi/` checkout:

```sh
make deploy
```

Should finish without prompting for any password (the sudoers whitelist
from step 10b is already in place). This pushes the full repo to the
Pi, symlinks the real `player.sh`, restarts the kiosk service, and
reloads nginx.

### 7. Configure your RTMP source

The ATEM Mini Pro is what we use. In ATEM Software Control:

1. **Settings → Output → Stream Service.** Add a custom destination
   using Blackmagic's
   [Streaming.xml generator](https://www.blackmagicdesign.com/) or by
   editing the Streaming.xml file directly.
2. **Server URL:** `rtmp://<pi-ip>/live` (e.g. `rtmp://192.168.0.106/live`)
3. **Stream key:** `church242` (or whatever you set in
   `install/setup-kiosk.sh`).
4. Press the LIVE button on the ATEM. The Pi should switch from the
   splash to your live feed within a few seconds.

For OBS Studio: same URL/key, plug into the *Stream* settings under
*Custom*.

For ad-hoc testing without the ATEM, see step 8.

### 8. Verify with a test stream

From the workstation:

```sh
make test-stream    # 60 s of 1080p test pattern + 440 Hz tone
```

The Pi should switch from splash to the test pattern within a few
seconds, you should hear a 440 Hz tone, and `make test-stream-long`
gives you 5 minutes if you need more time at the receiver.

If you can't hear audio:
[`docs/dev-journal/2026-04-25-hdmi-audio-routing.md`](dev-journal/2026-04-25-hdmi-audio-routing.md)
walks through the diagnosis.

## Day-to-day operations

All from the workstation, in the `display-pi/` checkout:

| Command              | What it does                                            |
|----------------------|---------------------------------------------------------|
| `make deploy`        | Push repo + restart kiosk service. No password prompts. |
| `make test-stream`   | 60 s test pattern with audio.                           |
| `make test-stream-long` | 5 min version, for in-place AV testing.              |
| `make ssh`           | Interactive shell on the Pi.                            |
| `make logs`          | Tail kiosk + nginx logs.                                |
| `make status`        | Show kiosk service status.                              |
| `make diag`          | Run diagnostics on the Pi (text output).                |
| `make ping`          | 3 pings to verify the Pi is reachable.                  |
| `make reboot`        | Reboot the Pi.                                          |
| `make sudoers`       | One-time: install the deploy sudoers whitelist (only needed if you skip step 5 or rebuild the Pi without re-running setup-kiosk.sh). |

To replace the splash image: drop your branded PNG at
`~/display-pi/images/splash.png` on the workstation and `make deploy`.
The deploy will copy it to `/home/kiosk/splash.png` if it differs.

To change the stream key, RTMP allow-list, or any other config: re-run
`bash install/setup-kiosk.sh` on the Pi after editing the config block at
the top. The script is idempotent and backs up everything it touches.

## Pi 4 vs Pi 5 — known differences

`setup-kiosk.sh` was developed against a Pi 4 and is the supported
reference platform. The Pi 5 should work, with these caveats:

- **`hdmi_enable_4kp60=1`** in `config.txt` is a Pi-4-only knob — the
  Pi 5 enables 4Kp60 by default on both micro-HDMI ports. The line is
  harmless on Pi 5 but unnecessary; you can remove it.
- **`dtoverlay=disable-bt`** — the overlay loads on both Pi 4 and Pi 5
  but routes through the RP1 chip on Pi 5; behavior should match. Verify
  with `bluetoothctl list` after setup if you care; should be empty.
- **Active cooling** — the Pi 5 will throttle without an active cooler
  during sustained 1080p H.264 decode. Get the official Active Cooler or
  equivalent.
- **PSU** — the Pi 5 *must* have the 5 V / 5 A PSU (or a USB-PD source
  capable of negotiating 5 A). With a 3 A PSU, USB ports are limited
  to 600 mA total and you will get random brownouts under load.
- **HDMI port enumeration** — both boards expose `vc4hdmi0` (HDMI 0,
  closer to the USB-C input) and `vc4hdmi1`; the project's pin to
  `CARD=vc4hdmi0` works on both.

If you're deploying a Pi 5 and hit something not covered here, please
add a note to `docs/dev-journal/`.

## Troubleshooting

### "No HDMI signal" on first boot

- Make sure the cable is in **micro-HDMI port 0** (closer to USB-C).
- Confirm `vc4.force_hotplug=1` is in `/boot/firmware/cmdline.txt`. If
  the TV was off when the Pi booted and the override is missing, the
  Pi negotiated zero modes and won't display until you reboot with the
  TV on first.
- Check `/sys/class/drm/card?-HDMI-A-1/status` over SSH — should say
  `connected`.

### Stream is live but no audio on HDMI

This was the original sin that started the journal. See
`docs/dev-journal/2026-04-25-hdmi-audio-routing.md`. Quick check:

```sh
ssh displaypi 'sudo grep audio-device /home/kiosk/bin/player.sh'
# Should show: --audio-device=alsa/plughw:CARD=vc4hdmi0,DEV=0
```

### Stream pushes from the ATEM but kiosk doesn't switch

- Verify nginx accepted the publish:
  ```sh
  make logs
  ```
  Look for `publish` entries with the ATEM's IP.
- Verify the ATEM's IP is in `RTMP_ALLOW_PUBLISH_CIDRS`.
- Verify the stream key matches.
- Verify port 1935 is reachable from the ATEM:
  ```sh
  nc -zv <pi-ip> 1935
  ```

### Kiosk service keeps crashing

```sh
make status        # see Restart=always firing
make ssh
journalctl --user -u kiosk.service --since '5 min ago'
sudo tail -100 /tmp/player.log
```

The most common causes are nginx not running (publisher path broken) or
the splash image missing/corrupted. The boot assessment screen will
show which check failed — wait for it to display on HDMI before the
splash takes over.

### `make deploy` asks for a password

The deploy sudoers whitelist isn't installed (or got deleted). Run:

```sh
make sudoers
```

This is the same step `setup-kiosk.sh` does as part of step 10b.

### Pi gets stuck at the rainbow boot screen

Almost always a cmdline.txt corruption — `setup-kiosk.sh` defends against
this with a backup-and-restore-on-error path, but if something else
edited the file:

1. Power off, pull the SD card.
2. On your workstation, mount the boot partition, fix cmdline.txt
   (must be exactly **one** non-empty line).
3. Re-insert and boot.

The script keeps timestamped backups at `/boot/firmware/cmdline.txt.bak-*`
so you can always restore.

## Where to look next

- **Architecture decisions:** `docs/dev-journal/`
- **What changed when:** `CHANGELOG.md`
- **Source of truth for the player loop:** `install/player.sh`
- **All the install knobs:** the config block at the top of `install/setup-kiosk.sh`
