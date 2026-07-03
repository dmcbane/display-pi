# display-pi

**The worship stream, on the lobby TV — automatically.**

A Raspberry Pi that shows a splash image until your service goes live, cuts to
the stream the instant it starts, and falls back to the splash when it ends. No
laptop, no operator, no Sunday-morning scramble.

[![Docs](https://img.shields.io/badge/docs-dmcbane.github.io%2Fdisplay--pi-blue)](https://dmcbane.github.io/display-pi/)
[![Releases](https://img.shields.io/badge/releases-latest-green)](https://github.com/dmcbane/display-pi/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-lightgrey)](LICENSE)

📖 **Full documentation:** <https://dmcbane.github.io/display-pi/>

---

## What it is

display-pi turns a single Raspberry Pi into a zero-touch RTMP lobby display for a
church worship stream. It is built for one job and done with the **fewest moving
parts** — a Pi that receives an RTMP push and drives an HDMI display, with no
state machine to babysit:

- **Automatic switching** — shows a splash image while idle, cuts to the live
  feed the moment a publisher starts pushing RTMP, and returns to the splash when
  the stream stops. No button to press.
- **Self-healing** — a hardware watchdog, a healthcheck cron, and a player that
  relaunches on crash keep the display alive through power blips and network
  hiccups.
- **Two ways in** — volunteers manage this Sunday's splash from a **browser**;
  admins keep full console access over SSH.

## How it works

```
 ATEM / OBS  ──RTMP──▶  nginx-rtmp  ──▶  mpv in cage  ──HDMI──▶  Lobby TV
 (switcher)             (:1935 on Pi)    (Wayland kiosk)
```

A systemd service runs `player.sh` under the `cage` Wayland compositor as the
`kiosk` user. The player waits for nginx, probes `rtmp://127.0.0.1/live/<key>`
with `ffprobe`, and either:

- **idle** → displays the next splash image (rotating through `SPLASH_DIR`, with
  the position persisted so it survives restarts), or
- **live** → plays the feed full-screen with hardware decode, falling back to the
  splash on end-of-stream.

Resilience is layered in: nginx drops subscribers when the publisher disconnects
or goes silent (so mpv sees EOF and returns to splash), `Restart=always` recovers
a crashed player, a `/dev/watchdog` guards against hard hangs, and
`health-monitor.sh` writes `/tmp/kiosk-health.json` every 20 s for the on-screen
health overlay and the web status board.

## Quick start

**Prerequisites:** a Raspberry Pi 4 or 5 running Raspberry Pi OS Lite (64-bit)
with SSH enabled and hostname `displaypi` (add a matching SSH alias on your
workstation).

```sh
make provision HOST=displaypi STREAM_KEY=restoration
```

`provision` runs the four one-time steps in dependency order —
`setup → deploy → setup-web → volunteer-web-url` — and is idempotent, so
re-running it on an existing Pi just tops everything off. Then point your ATEM (or
OBS) at `rtmp://displaypi/live` and press LIVE.

No DHCP on the target network? Bind a fixed fallback address alongside the normal
lease:

```sh
make provision HOST=displaypi STATIC_IP=192.168.50.1/24
```

See the [Setup Guide](https://dmcbane.github.io/display-pi/setup-guide.html) for
the full fresh-Pi-to-Sunday runbook.

## Managing it

### Volunteers — the web manager (primary)

One bookmarked link, no login screen — works from a phone or any browser. From it
a volunteer can:

- Upload / delete / download splash images (PNG or JPEG, exactly 1920×1080,
  ≤ 10 MB) and drag-and-drop (or ↑↓) to reorder the rotation
- **Restart Service** or **Reboot Pi**
- Watch a live **System Status board** — network, nginx/RTMP, disk, memory, CPU
  temperature, time sync, watchdog, and player health, green/amber/red at a
  glance (the same board shown on the HDMI boot screen)
- Copy the access link or download a `.webloc` (Mac) / `.url` (Windows/Linux)
  shortcut, and **Rotate Token** to instantly invalidate a leaked link

Stand it up (also done by `make provision`):

```sh
make setup-web                       # one-time: installs the manager (HTTPS via a local cert)
make web-ca                          # fetch the Pi's root CA to trust once per device
make volunteer-web-url               # writes the volunteer shortcut files
make setup-web-tls DOMAIN=kiosk.example.org   # alternative: publicly-trusted Let's Encrypt cert
```

Details in [Web Manager — Splash, Status, HTTPS & Tokens](https://dmcbane.github.io/display-pi/web-manager-https.html).

### Admins — the console

Everything the browser tool does has a command-line counterpart, plus the deeper
stuff:

```sh
make ssh          # interactive shell on the Pi
make logs         # tail player + nginx logs
make status       # is the kiosk service healthy?
make deploy       # push code changes + restart the player
make diag         # full diagnostics dump
```

### Splash images — offline fallback

Where a browser or HTTPS isn't available, `make volunteer-bundle` builds a
hand-delivered SSH-key bundle (`splash-replace.sh` / `.ps1`) a volunteer can use
to push a slide over SSH. This is the secondary path — see the
[offline splash guide](https://dmcbane.github.io/display-pi/volunteer-splash-update.html).

## Security model

The web manager is built to be handed to volunteers safely:

- Runs as a **locked `kiosk-web` system user** (no login, no home) that cannot
  read `/home/kiosk`; its app code in `/opt/kiosk-web` is root-owned.
- **Minimal sudoers** — only `systemctl --user restart kiosk.service` and
  `reboot`.
- Auth is a bearer **token** (constant-time compared) that, on first use, mints a
  hardened **persistent cookie** (`HttpOnly`, `SameSite=Strict`, `Secure` over
  TLS) so the secret leaves the URL; the token is **rotatable** from the UI into
  an app-owned `/var/lib/kiosk-web/token` file with no elevated privilege.
- **HTTPS on by default** with a locally-signed cert — a per-Pi CA you trust once
  per device, no domain or internet required; Let's Encrypt DNS-01 is available
  if you do have a domain. The `?token=` is stripped from nginx access logs.

## Project layout

| Path           | What's in it                                                        |
|----------------|---------------------------------------------------------------------|
| `install/`     | Everything that runs on the Pi: `setup-kiosk.sh`, `player.sh`, systemd units, nginx, sudoers, web-manager setup |
| `web/`         | `kiosk_manager.py` — the single-file Flask volunteer web manager     |
| `diagnostics/` | Health/observability: status-board render, health monitor, judder tools |
| `dev/`         | Workstation-side helpers invoked by `make` (deploy, stream test, …)  |
| `docs/`        | The Jekyll GitHub Pages site                                         |
| `images/`      | Default `splash.png` and the `splash.d/` rotation folder             |
| `tests/`       | `pytest` suite for the web manager + the `run-tests.sh` harness      |

## Development & testing

```sh
make test     # runs tests/run-tests.sh (auto-creates a venv on first run)
make lint     # shellcheck the shell scripts
make check    # lint + test
```

`make help` lists every target.

## Versioning & license

Releases follow [Semantic Versioning](https://semver.org/); changes are recorded
in [CHANGELOG.md](CHANGELOG.md). Licensed under [Apache-2.0](LICENSE).
