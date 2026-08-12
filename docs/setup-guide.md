---
title: Setup Guide — display-pi
description: End-to-end procedure for turning a blank Raspberry Pi into a working RTMP-driven kiosk display.
---

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
| Board           | Pi 4 Model B, 2 GB is enough (4/8 GB for headroom) | Pi 5, 4 GB or 8 GB                 |
| Power supply    | Official 5 V / 3 A USB-C            | Official 5 V / 5 A USB-C-PD        |
| Cooling         | Passive heatsink fine               | Active cooler strongly recommended |
| Storage         | 32 GB+ SD card (Samsung Pro / SanDisk Extreme — avoid no-name) |
| HDMI            | Micro-HDMI to HDMI cable, port 0    | Same                               |
| Network         | Ethernet preferred — RTMP video on Wi-Fi is unreliable |
| Capture (optional) | USB3 HDMI capture (e.g. MACROSILICON 345f:2131) on the workstation for visual debugging |

> **On RAM:** a 2 GB Pi 4 is fine for the relay-only kiosk role. nginx
> *relays* the RTMP push (no transcode) and mpv decodes in hardware
> (`--hwdec=v4l2m2m-copy`), so the whole stack sits well under 1 GB. The
> real reliability levers are cooling, SD-card quality, and Ethernet —
> not memory. Step up to 4/8 GB only if you add a second job to the same
> Pi (recording, a browser overlay, a MediaMTX relay).

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
- **RTMP allow-list** — the CIDR(s) permitted to push RTMP. Default is the
  wired LAN `192.168.0.0/24`; tighten to the ATEM's exact IP (e.g.
  `192.168.0.42/32`) for even better hygiene once it's stable. The stream key
  is not a secret, so this allow-list is the real control on who can push to
  the display.
- **Stream key** — defaults to `restoration`. The ATEM and the kiosk
  must agree on this.
- **Static fallback IP (optional)** — if you ever need to reach the Pi on a
  network with **no DHCP server** (a laptop patched straight into the Pi, a
  dumb switch, a field rig), set `STATIC_IP` and the Pi will bind an extra
  fixed address *in addition* to DHCP. Set it to something outside your normal
  LAN range so it never collides — e.g. `192.168.50.1/24`. See
  [Optional: a static fallback IP](#optional-a-static-fallback-ip) below.

## Installation procedure

> **Fast path:** once steps 1–4 are done (flash, first boot, SSH config, repo
> checkout on the workstation), a single command takes the Pi the rest of the
> way — base kiosk, full deploy, volunteer web manager, and shortcut files:
>
> ```sh
> make provision HOST=displaypi STREAM_KEY=restoration
> ```
>
> It runs `setup` → `deploy` → `setup-web` → `volunteer-web-url` in that order
> (the order matters — see `make help`), and every step is idempotent so it's
> safe to re-run. Steps 5–8 below do the same work by hand and explain each
> piece; read them to understand what `provision` automates, or to run a step
> on its own.
>
> Provisioning several cards, or re-flashing one? See
> [Batch provisioning](#batch-provisioning-re-flashed-cards-and-spare-pis)
> for the per-card loop, including the `known_hosts` cleanup a re-flash
> requires.

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
are sane for a 192.168.x.x LAN with a `restoration` stream key — read the
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
5b. If `STATIC_IP` is set, binds an extra static IP on Ethernet alongside
   DHCP (see [Optional: a static fallback IP](#optional-a-static-fallback-ip)).
   Skipped when `STATIC_IP` is empty.
6. Creates the **splash store** at `/var/lib/kiosk-splash` — the one folder
   every splash image lives in — records it as `SPLASH_DIR` in
   `/etc/default/kiosk`, and seeds it. The repo's `images/splash.d/` rotation
   set is used if it exists; failing that `images/splash.png` becomes slide
   `01-`; failing that, and only on an interactive run, setup prompts you to
   pick from whatever else is in `images/`; with no usable image at all it
   generates a placeholder from `$SPLASH_TEXT`. Seeding happens **only when
   the store is empty**, so re-running setup never overwrites your slides.
7. Installs a minimal bootstrap player script (overwritten by the full
   one when you `make deploy`)
8. Installs the systemd user service
9. Configures the hardware watchdog
10. Configures PipeWire client.conf
10b. Installs the deploy sudoers whitelist (`/etc/sudoers.d/kiosk-deploy`)
10c. Generates the system locale (`DISPLAY_LOCALE`, default `en_US.UTF-8`),
   makes it the default, and strips `LANG`/`LC_*` from sshd's `AcceptEnv` so
   an SSH login never shows the *cannot change locale* warning — no matter
   what the client forwards (see
   [Optional: change the system locale](#optional-change-the-system-locale)).
11. Installs logrotate config
12. Installs the healthcheck cron stub

When it finishes, **reboot**:

```sh
sudo reboot
```

After ~30 s the Pi will come back into kiosk mode: a brief boot
diagnostics screen, then the splash image. From here on, you do not
need to log into the Pi for routine work.

#### Optional: a static fallback IP

On a normal LAN the Pi gets its address from DHCP and you never think about
this. But sometimes there's no DHCP server — you've patched a laptop straight
into the Pi with one cable, plugged it into a dumb switch, or set it up in the
field. Set `STATIC_IP` and the Pi binds a fixed IPv4 address **in addition** to
its DHCP lease, so it's reachable at a known address in both situations:

```sh
# During setup (or provision), from the workstation:
make setup STATIC_IP=192.168.50.1/24 HOST=displaypi
```

Pick a subnet outside your normal LAN range (e.g. `192.168.50.0/24`) so the
static address never collides with a real DHCP lease. NetworkManager keeps
requesting DHCP as usual, so this is purely additive — it does not change how
the Pi behaves on your regular network.

To reach the Pi over the fallback address, give the connecting machine another
address in the same subnet and SSH across:

```sh
# On the laptop, once cabled to the Pi (macOS/Linux example):
sudo ip addr add 192.168.50.2/24 dev eth0
ssh rpi@192.168.50.1
```

Notes:

- The change applies on the **next reboot** — setup does not bounce the live
  connection (that would drop the SSH session it runs over). To activate it
  immediately instead, run `sudo nmcli connection up kiosk-static` on the Pi
  (expect a brief network blip if you're SSH'd in over that NIC).
- It's implemented as a dedicated NetworkManager profile named `kiosk-static`
  with a higher autoconnect priority than the stock `Wired connection 1`.
  Re-running setup recreates it cleanly, so addresses never stack up.
- By default no gateway or DNS is set on the static address — it's for direct
  reach, not the Pi's default route (DHCP still supplies the real route
  wherever the Pi is plugged in). If the static address is the Pi's *primary*
  identity on a DHCP-less network and it needs a route/resolver, pass them
  explicitly: `make setup STATIC_IP=192.168.50.1/24
  STATIC_GATEWAY=192.168.50.254 STATIC_DNS=192.168.50.254,1.1.1.1`.
- Reachability is a *routing* question, not a gateway-on-the-Pi question: a
  machine on a **different subnet** (say your laptop at `192.168.1.x/24`
  trying to reach `192.168.0.106`) can only get there if *its* router knows a
  route to that subnet. On the same L2 segment, give the connecting machine an
  address in the static subnet (as in the example above) and it works with no
  gateway anywhere.
- To remove it later, re-run with `STATIC_IP=none`:
  `make setup STATIC_IP=none HOST=displaypi`.

#### Optional: change the system locale

By default the Pi is set to `en_US.UTF-8`, and — importantly — sshd is told to
**ignore** the locale your SSH client forwards. That combination means every
login is clean and identical no matter which machine you connect from: no more

```
-bash: warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)
```

You don't have to do anything to get this; it's part of the base setup. If your
region isn't US English, set `DISPLAY_LOCALE` so the Pi's default matches:

```sh
make setup DISPLAY_LOCALE=en_GB.UTF-8 HOST=displaypi
```

Why the warning happened in the first place: a fresh Raspberry Pi OS image has
almost no locales generated, but most SSH clients forward `LANG`/`LC_*` from the
desktop they run on. When the Pi doesn't have that locale, every program that
reads it complains. Setup fixes both halves — it generates the default locale
*and* stops sshd from importing the forwarded values — so the result no longer
depends on the client at all.

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
3. **Stream key:** `restoration` (or whatever you set in
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
[`docs/dev-journal/2026-04-25-hdmi-audio-routing.md`](https://github.com/dmcbane/display-pi/blob/main/docs/dev-journal/2026-04-25-hdmi-audio-routing.md)
walks through the diagnosis. (The dev journal isn't part of the published
site — the notes live on GitHub as plain Markdown.)

## Batch provisioning (re-flashed cards and spare Pis)

When you're provisioning several SD cards in a row — spares, an OS upgrade, a
second display — steps 3–8 collapse into a short per-card loop. Only two
things need attention beyond `make provision`, and both live on the
**workstation**, not the Pi:

1. **A stale host key.** A re-flashed card generates a brand-new SSH host key
   at first boot, so the entry left in `~/.ssh/known_hosts` by the previous
   card no longer matches and SSH refuses to connect
   (`REMOTE HOST IDENTIFICATION HAS CHANGED!`).
2. **Your public key isn't on the card yet** — unless you pre-loaded it on the
   Imager's customisation screen (step 1).

So, for each card, after flashing (step 1) and first boot (step 2):

```sh
# 1. Forget the previous card's host key. Entries are keyed by exactly what
#    you type on the ssh command line — if you connect by both the alias and
#    the raw IP, remove both.
ssh-keygen -f "$HOME/.ssh/known_hosts" -R displaypi
ssh-keygen -f "$HOME/.ssh/known_hosts" -R 192.168.0.106

# 2. Install your public key on the fresh OS (skip if the Imager pre-loaded
#    it; the first connection re-learns the new host key here).
ssh-copy-id -i ~/.ssh/id_ed25519 displaypi

# 3. Provision end to end (HOST defaults to displaypi; STATIC_IP only if you
#    want the no-DHCP fallback address).
make provision STREAM_KEY=restoration STATIC_IP=192.168.50.1/24 \
    RTMP_ALLOW_PUBLISH_CIDRS=192.168.0.42/32

# 4. Smoke-test: land a shell on the new card, then send it a test pattern.
make ssh
make test-stream
```

Because every `provision` step is idempotent, this same loop also re-runs
safely on a card that only half-finished — just start it again from the top.

> **Note:** command-line values like `STREAM_KEY` and
> `RTMP_ALLOW_PUBLISH_CIDRS` persist on the Pi in `/etc/default/kiosk`, so a
> later bare `make setup` won't reset them — but a *re-flashed* card starts
> from nothing, so pass the full set of overrides you care about every time
> you run this loop. `RTMP_ALLOW_PUBLISH_CIDRS` is the one that bites
> silently: it's the real control on who can push to the display (see
> [Network plan](#network-plan)), and a card provisioned without it quietly
> reverts to the default `192.168.0.0/24` allow-list.

### Script it: one file per site

Once you've run that loop twice, write it down. A per-site script turns
provisioning into one command you can hand to someone else, and — more
usefully — it records the handful of values that make *this* site different
from the last one. Keep one file per site next to the repo:

```sh
#! /usr/bin/env bash
#
# restoration_setup.sh — provision the Restoration lobby kiosk from a bare Pi.
#
# Run from the repo root on the workstation, after flashing (step 1) and
# first boot (step 2).

# Fail loudly: a step that dies silently leaves a half-provisioned Pi, which
# is harder to diagnose than one that never started.
set -euo pipefail

PI=displaypi                        # this site's ~/.ssh/config alias
FIRST_BOOT_IP=192.168.1.172         # DHCP address before the static IP lands
KEY=~/.ssh/id_ed25519_restoration   # the key this site's Pi should trust

# 1. A re-flashed card generates a new host key, so forget the old one. Exits
#    0 when there's no entry, so this is safe on a first run too.
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$FIRST_BOOT_IP"
ssh-copy-id -i "$KEY" "$PI"

# 2. Provision end to end, then fetch the root CA for a warning-free padlock.
#    Pass the FULL set of overrides — a re-flashed card starts from nothing.
make provision STREAM_KEY=restoration STATIC_IP=192.168.50.1/24 \
    RTMP_ALLOW_PUBLISH_CIDRS=192.168.0.42/32
make web-ca

# 3. Drop the seed slides this site doesn't want. `splash-store path` is the
#    one authority on where the store lives — never hardcode the directory.
ssh "$PI" 'sudo rm -f "$(splash-store path)"/01-example.png'
make restart

# 4. Stage the handout files in the login user's home directory. An admin who
#    can only reach the Pi over a console session — an iPad SSH client, say,
#    with no scp and no repo checkout — can then read them straight off the Pi.
scp volunteer-kiosk.webloc volunteer-kiosk.url display-pi-rootCA.crt "$PI":
ssh "$PI" 'chmod 600 ~/volunteer-kiosk.webloc ~/volunteer-kiosk.url'

# 5. Show your work, so a bad run is obvious before you leave the building.
echo "Restoration kiosk provisioned."
ssh "$PI" 'ls -l ~/volunteer-kiosk.webloc ~/volunteer-kiosk.url ~/display-pi-rootCA.crt'
make splash-ls
```

Provisioning a second site is then a copy of this file with a different block
of constants at the top — stream key, static IP, publish CIDR, key path, and
which seed slides to prune.

A few things worth knowing before you adapt it:

- **Keep it out of git.** The script names your private key path and your
  internal addressing, and this repo is public. Add it to `.gitignore`
  (`*_setup.sh` covers the whole family) and it still sits right where you
  need it, next to the `Makefile`.
- **The shortcut files carry a live token.** `volunteer-kiosk.webloc` and
  `.url` are generated from the Pi's current access token, so anyone holding
  one can change what the display shows. `chmod 600` is the reason step 4 ends
  the way it does — and it's why `make deploy` deliberately refuses to ship
  them to the Pi's repo copy (see the `.gitignore` filter in `dev/deploy.sh`).
  If you rotate the token in the web manager, re-run `make volunteer-web-url`
  and re-copy them.
- **`set -euo pipefail` changes the failure mode.** The script now stops at the
  first error instead of plowing on. That's the point, but it means a step that
  used to fail quietly will halt the run — which is what you want when the
  alternative is discovering it on Sunday morning.
- **Re-running is safe.** Every `make provision` step is idempotent, so a
  script that died halfway can just be run again from the top.
- **Mind where the Pi is when the static IP lands.** Everything after
  `make provision` still talks to `$PI`. If `STATIC_IP` moves the Pi to a
  subnet your workstation can't reach and takes effect immediately rather than
  at the next boot, those later steps will fail on a dead host — provision on
  the bench first, then move it.

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
| `make ssh-password`  | Toggle SSH password login: `STATE=on` (key OR password), `STATE=off` (key-only), `STATE=status` (default, just report). |
| `make ping`          | 3 pings to verify the Pi is reachable.                  |
| `make reboot`        | Reboot the Pi.                                          |
| `make shutdown`      | Power off the Pi (`sudo poweroff`).                     |
| `make sudoers`       | One-time: install the deploy sudoers whitelist (only needed if you skip step 5 or rebuild the Pi without re-running setup-kiosk.sh). |

### Splash images

Every splash image on the Pi lives in **one** folder, the splash store:

```
/var/lib/kiosk-splash        # or whatever SPLASH_DIR in /etc/default/kiosk says
```

Ask the Pi rather than assuming — `make splash-ls` prints the live path and
lists what is in it.

The kiosk cycles through that folder whenever the stream is idle, **advancing
one image each time the splash comes back up** (when the stream drops, or the
kiosk service restarts). There is no timer — a single continuous idle period
shows one image until the splash is re-entered. The cursor is persisted to
`/home/kiosk/.splash-index`, so it keeps moving across restarts instead of
snapping back to the first slide (this is what makes `make restart` step to the
next image during testing).

The store is owned by the `kiosk` user until the web manager is installed, and
by `kiosk-web` after that. `become-kiosk-web` drops you into a shell as its
owner, already in the folder — that account is `nologin`, so plain
`sudo -u kiosk-web -i` will not work.

- **Who writes to it:** the volunteer web manager (uploads, deletes, reorder),
  the SSH-bundle updater (`00-volunteer.*`), and provisioning — which **seeds
  the store only when it is empty**. A `make deploy` will not overwrite slides
  that are already there; the repo's `images/splash.d/` is a first-install
  seed, not a live mirror.
- **Changing the slides on a running Pi:** use the web manager, or
  `become-kiosk-web` and edit the folder directly. Editing
  `images/splash.d/` in the repo and deploying will **not** change what is on
  screen — the store is already populated by then.
- **Empty store:** the player logs an error and shows nothing. There is no
  second location to fall back to, on purpose: the old fallback let a missing
  folder hide behind a stale image.
- **Cycle manually while testing:** `make restart` (advances one slide), or send
  a `make test-stream` and let it end (a stream toggle also advances one).
- **Volunteers** replace their slides from the browser-based web manager
  (below) — upload, delete, and reorder, then **Restart Service**. Hand them
  [`docs/volunteer-splash-update.md`](volunteer-splash-update.md); it is the
  only volunteer-facing path.

### The volunteer web manager

`make provision` (or `make setup-web`) installs a browser-based manager that lets
volunteers swap splash images, restart or reboot the Pi, and watch a live
**System Status** board — all from one bookmarked link, no SSH key required. The
link carries an access token you can **rotate** in one click if it leaks.

The manager is served over **HTTPS by default** with a certificate signed by a
small CA generated on the Pi — no domain needed. Trust that CA once per device
for a warning-free padlock:

```sh
make web-ca HOST=displaypi   # saves display-pi-rootCA.crt — import it as a trusted root
```

If you control a domain, `make setup-web-tls DOMAIN=…` swaps in a publicly-trusted
Let's Encrypt cert instead (no per-device import). Full walkthrough:
[Web Manager — Splash, Status, HTTPS & Tokens](web-manager-https.html).

### SSH password login

`setup-kiosk.sh` configures the Pi to accept SSH login by **public key OR
password**. The setting lives in a single drop-in,
`/etc/ssh/sshd_config.d/00-display-pi-auth.conf`, whose `00-` prefix makes it
sort first and win sshd's first-value-wins resolution over any later drop-in
(including the key-only file rpi-imager writes) and the stock config.

Flip it without hand-editing config:

```bash
# From the workstation:
make ssh-password STATE=off      # key-only (hardened)
make ssh-password STATE=on       # allow public key OR password again
make ssh-password                # STATE=status — show the effective setting
```

Public-key auth is **always** kept enabled, so `STATE=off` can never lock out
key-based logins. The toggle validates with `sshd -t` and applies with a
reload (not a restart), so the SSH session you run it from stays up even if the
new config were rejected. On the Pi directly:
`sudo bash install/sshd-password-toggle.sh on|off|status`.

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
- Testing with `make test-stream` rather than the ATEM? Its preflight checks
  the allow-list and the stream key for you — see
  [`make test-stream` refuses to run](#make-test-stream-refuses-to-run).

### `make test-stream` refuses to run

Before starting ffmpeg, `test-stream.sh` reads the Pi's own config and checks
the two things that make a test stream fail without saying why. If either is
wrong it stops in about a second rather than burning the full 60.

**"this workstation cannot publish to …"**

```
  your source address:  192.168.1.131
  Pi allows publish from: 192.168.0.0/24
```

Your workstation is outside `RTMP_ALLOW_PUBLISH_CIDRS`, so nginx accepts the
TCP connection and immediately drops it. Without the preflight this surfaces
only as ffmpeg's `Broken pipe`, forty lines below the libx264 statistics — a
message that names neither nginx nor the allow-list.

This is the normal state when the Pi is provisioned for the church LAN
(`192.168.0.0/24`, where the ATEM lives) but is sitting on a different bench
network. To test anyway, add your address on the Pi — the persisted value in
`/etc/default/kiosk` wins over the repo default:

```sh
ssh displaypi 'sudo kiosk-config'   # RTMP_ALLOW_PUBLISH_CIDRS="192.168.0.0/24 192.168.1.131/32"
make deploy                         # re-render nginx.conf and reload
make test-stream
```

A single `/32` for your workstation is enough — no need to open a whole
subnet. **Narrow it again before the Pi goes into service:** that list is the
real control on who can push to the display.

**"Using the Pi's stream key 'church242' (local value was 'restoration')"**

Not an error — the preflight adopting the key the Pi actually watches. The
Makefile defaults `STREAM_KEY` to `restoration`, and nginx accepts *any* key
inside the `live` app, so publishing under the wrong one succeeds while the
display never switches and nothing logs an error. The preflight prevents that
silent non-event, and says so rather than substituting quietly.

**"couldn't read /etc/default/kiosk … preflight skipped"**

SSH to the Pi failed, so neither check could run. The stream is still
attempted, since the RTMP port may be reachable where SSH isn't. If it then
dies with `Broken pipe`, assume the allow-list.

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
