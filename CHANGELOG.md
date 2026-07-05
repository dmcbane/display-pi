# Changelog

All notable changes to display-pi are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.24.0] - 2026-07-05

### Fixed
- **A custom `STREAM_KEY` now survives `make provision`/`make deploy`.**
  Provision step 1 (setup) baked the key into a generated
  `/home/kiosk/bin/player.sh`, then step 2 (deploy) replaced that file with a
  symlink to the repo's `install/player.sh`, which hardcoded the default key —
  so the Pi always subscribed to `live/restoration` no matter what was passed
  (2026-07-05 field failure). `/etc/default/kiosk` is now the one persistent
  config store: setup writes `STREAM_KEY`/`RTMP_APP`/`STREAM_URL`/`VOLUME`/
  `RTMP_ALLOW_PUBLISH_CIDRS` there, `kiosk.service` loads it via
  `EnvironmentFile=`, and `player.sh`, `render-status.sh`, and `judder.sh`
  honor the env override (falling back to reading the file directly when run
  outside the service). Deploy never touches the file.
- **nginx-rtmp pinned to one worker.** `worker_processes auto` gave each of
  the Pi 4's four workers its own private RTMP state: the publisher landed on
  one worker while mpv subscriptions and `/stat` queries hit random others —
  playback start was a retry lottery and the status board usually reported no
  publisher even mid-stream. One worker easily serves one stream plus the
  proxied web manager, and makes `/stat` and playback deterministic.
- **Web manager shows the configured stream and live publishers.** The status
  board gains a "Player Stream" row (key + URL read fresh from
  `/etc/default/kiosk`) and one "Publisher" row per stream connected to
  nginx-rtmp (key, source IP, Mb/s from the loopback `rtmp_stat` endpoint) —
  WARN with the expected key named when a publisher pushes to the wrong key.
  The ffprobe stream check uses the configured URL instead of a hardcoded
  default, with tightened `analyzeduration`/`probesize` so a live stream
  answers inside the check budget on Pi hardware.
- **Setup re-runs keep configured values.** `make setup` forwards only
  variables explicitly set on the command line or environment (`$(origin)`
  check); everything else keeps its persisted `/etc/default/kiosk` value, so
  `make setup HDMI_MODE=…` months later can no longer silently reset the
  stream key or volume to defaults. The bootstrap player generator also
  replaces a deploy-installed symlink instead of writing through it into the
  deployed repo copy.
- **Deploy no longer clobbers a configured nginx.conf.** Both setup and
  deploy render `install/nginx.conf` through the new
  `install/render-nginx-conf.sh`, substituting the persisted `RTMP_APP` and
  allow-publish CIDRs — previously setup generated its own (stale) copy and
  deploy overwrote it with the repo template, reverting custom values.

### Added
- **`STATIC_GATEWAY` / `STATIC_DNS`** (setup only): optional gateway and DNS
  for the `kiosk-static` profile, for when the static address is the Pi's
  primary identity on a DHCP-less network. Default remains a gateway-less
  direct-reach extra address with DHCP owning the routes. Setup output and
  docs now spell out that the profile activates on reboot (or
  `sudo nmcli connection up kiosk-static`) and that cross-subnet reachability
  is a routing question on the connecting side, not a missing gateway on the
  Pi.

## [0.23.0] - 2026-07-04

### Added
- **Status screen shows the player's stream/key and every publisher connected
  to the Pi.** `diagnostics/render-status.sh` gains a "Player Stream" row with
  the key and URL the player subscribes to (env-overridable `STREAM_URL`, same
  default as player.sh), plus one "Publisher" row per stream currently being
  pushed to nginx-rtmp — key, source IP, and Mb/s, read from the loopback
  `rtmp_stat` endpoint via a new `status` mode in `parse_stat.py`. A publisher
  pushing to the wrong key is flagged WARN with the expected key named, so the
  2026-05-03 splash-stuck-while-publisher-connected failure mode is readable
  on the HDMI screen without SSH. The ffprobe stream check now uses the same
  `STREAM_URL` instead of its own hardcoded copy.

### Changed
- **Status-screen checks run concurrently.** Each health check runs as a
  background job and results are collected in display order afterwards, so
  the screen renders in the time of the slowest single check (~5s ffprobe
  timeout) instead of the sum of all of them — this script sits on the boot
  path via assess.sh. A check that crashes now surfaces as its own WARN row
  instead of taking the whole render down with `set -e`.

## [0.22.2] - 2026-07-03

### Fixed
- **Faster splash→stream switch.** The player's idle loop re-probed for a live
  publisher only every 3s, so the display could sit on the splash for up to ~3s
  after the stream went live — enough that `make test-stream` looked like it
  "wasn't triggering." An idle `ffprobe` fails in ~0.45s, so the poll is cheap;
  the interval is now a named, env-overridable constant (`STREAM_POLL_INTERVAL`)
  defaulting to 1s, cutting worst-case switch lag roughly 3×. nginx was not
  involved — the RTMP config was intact throughout.

## [0.22.1] - 2026-07-03

### Fixed
- **`setup-web-tls` installs certbot on demand.** The Let's Encrypt path is the
  optional HTTPS alternative and `certbot` isn't part of the base kiosk install
  (the default local-cert path doesn't need it), so the script now
  `apt-get install`s certbot when it's missing instead of only erroring out. It
  also warns if the DNS provider plugin named in `CERTBOT_ARGS` isn't present
  (that plugin still has to be installed for your provider). Docs updated to
  match.

## [0.22.0] - 2026-07-03

### Changed
- **HTTPS is now the default for the web manager, via a locally-signed
  certificate** — `make setup-web` (and `make provision`) generate a per-Pi root
  CA and a server cert signed by it (Subject Alt Names: the hostname,
  `<hostname>.local`, and every LAN IP), install an nginx block that serves the
  manager over TLS with HSTS and 301-redirects `:80`, and set
  `PUBLIC_URL=https://<hostname>`. No domain, DNS, or internet required. The root
  CA is fetchable over plain HTTP at `/rootCA.crt` (or `make web-ca`) so each
  device can trust it once for a warning-free padlock — and because HSTS is only
  seen after a successful TLS handshake, it can't lock out a device that hasn't
  imported the CA. The root CA is stable across runs while the server cert is
  re-issued each run to track a changed hostname/DHCP address
  (`make setup-web-tls-local`). The Let's Encrypt DNS-01 path
  (`make setup-web-tls DOMAIN=…`) stays as the alternative for a publicly-trusted
  cert with no per-device import. New: `install/kiosk-web-tls-local.sh`,
  `make setup-web-tls-local`, `make web-ca`; `install/kiosk-web-setup.sh` now
  calls the local-TLS path by default.

## [0.21.0] - 2026-07-03

### Added
- **Cookie-hardened auth for the web manager** — a valid `?token=` now mints a
  hardened cookie (`HttpOnly`, `SameSite=Strict`, `Path=/`, and `Secure`
  whenever the request arrives over TLS, derived from nginx's
  `X-Forwarded-Proto`). The cookie is **persistent (90 days)** so a bookmarked
  clean URL keeps working across browser restarts. On load the page scrubs the
  `?token=` from the address bar (`history.replaceState`, so it isn't one
  Back-press away), and rotation no longer re-plants it there. Every request
  after the first authenticates from the cookie, so the token stays out of
  browser history, `Referer`, and logs. The cookie carries the live token
  verbatim — no server-side session store — so **rotating the token
  invalidates outstanding cookies** just like it does links, and a rotation
  re-keys the admin's own cookie in the same response. Shareable links still
  carry `?token=` for first contact on a fresh device. The cookie is only
  issued for requests that authenticated via URL token; denied requests never
  receive one. See `auth()` / `issue_auth_cookie()` in `web/kiosk_manager.py`.

## [0.20.1] - 2026-07-03

### Added
- **Documentation link in the web manager** — a footer link to the published
  documentation site (<https://dmcbane.github.io/display-pi/>) now appears
  beneath the manager's cards, opening in a new tab.

## [0.20.0] - 2026-07-03

### Added
- **Rotatable access token in the web manager** — an "Access Link" card now
  shows the current volunteer link with a copy button, downloadable
  `.webloc` (Mac) and `.url` (Windows/Linux) shortcut files generated
  server-side from the live token, and a **Rotate Token** button that
  invalidates every existing link and re-keys the open page in place (no
  logout). The live token is stored in an app-owned file
  `/var/lib/kiosk-web/token` (`0600`, written atomically); the `TOKEN=` in
  `/etc/kiosk-web.conf` becomes a one-time *seed* used only until the first
  rotation. This needs **no new privilege** — the locked `kiosk-web` user
  simply owns its own state dir rather than being granted write access to
  root's config or a setuid helper. New endpoints: `GET /api/token`,
  `POST /api/token/rotate`, `GET /api/token/webloc`, `GET /api/token/url`.
  Token comparison now uses `secrets.compare_digest` (constant-time). Shortcut
  files embed a canonical base URL from `PUBLIC_URL` (falling back to the
  request host) so a downloadable link can't be poisoned by a spoofed `Host`
  header. `kiosk-web-setup.sh` and `deploy.sh` create the `0700` state dir.
- **HTTPS for the web manager** — `install/kiosk-web-tls-setup.sh`
  (`make setup-web-tls DOMAIN=…`) obtains a Let's Encrypt cert via the DNS-01
  challenge (so the Pi never needs to be internet-reachable), writes an HTTPS
  nginx server block with an HTTP→HTTPS redirect and HSTS, sets
  `PUBLIC_URL=https://<domain>`, and installs a renewal hook that reloads
  nginx. The volunteer server block moved out of `nginx.conf` into a wildcard
  include (`/etc/nginx/kiosk-web-site.d/*.conf`) so the domain-specific TLS
  config survives `deploy.sh` overwriting `nginx.conf`; `deploy.sh` seeds the
  default HTTP block before reloading so existing installs never lose their
  server block mid-deploy. A new `kiosk_redacted` nginx log format strips the
  query string, keeping the `?token=` bearer credential out of the access log
  even before TLS. New doc: `docs/web-manager-https.md`.

## [0.19.0] - 2026-07-03

### Added
- **System Status board in the web manager** — the volunteer Kiosk Manager now
  carries the same health board shown on HDMI at boot (`render-status.sh`),
  turning it into a fuller remote console. A new `GET /api/status` endpoint
  runs a Python port of the boot-time checks — Hostname, Network, Gateway, Link
  speed/errors, nginx RTMP, RTMP Stream, Disk, Memory, CPU Temp, Uptime, Time
  Sync, Watchdog — plus a **Kiosk Player** row sourced from the world-readable
  `/tmp/kiosk-health.json` that `health-monitor.sh` maintains (the one liveness
  fact the locked `kiosk-web` user can't compute itself; flagged if the
  snapshot goes stale). The checks are re-implemented in-process rather than
  shelled out because the web app is installed as a standalone file and can't
  read the repo under `/home/kiosk`; the two session-only boot checks (Display
  Mode, Audio) are omitted since they'd only ever WARN from this context. The
  page is now a **two-column layout** — splash images and controls on the left,
  the live status board on the right (auto-refreshing every 15 s, with a manual
  refresh) — and collapses to a single column on narrow screens. Each check
  shows a green/amber/red dot with label and detail, and a summary banner rolls
  up the worst status. No new privileges or deploy paths: every probe is an
  unprivileged `/proc`, `/sys`, socket, or `systemctl is-active` read.

## [0.18.0] - 2026-07-01

### Added
- **`configure_locale` setup step** — a fresh SSH login no longer shows the
  `-bash: warning: setlocale: LC_ALL: cannot change locale` warning, and the
  outcome is deterministic regardless of which machine someone connects from.
  Two independent causes are both fixed: (1) `setup-kiosk.sh` generates
  `DISPLAY_LOCALE` (default `en_US.UTF-8`) and makes it the system default, and
  (2) it strips `LANG`/`LC_*` from sshd's `AcceptEnv` so the client's forwarded
  locale is ignored entirely — the session always uses the Pi's own default.
  The `AcceptEnv` edit preserves other tokens (`COLORTERM`, `NO_COLOR`),
  comments the directive out if that empties it, and is validated with
  `sshd -t -f` on a temp copy before install so a bad edit can never leave sshd
  unable to start. Idempotent: an already-generated locale and an
  already-stripped `AcceptEnv` are left untouched on re-run. Exposed via
  `make setup`/`make provision` as `DISPLAY_LOCALE` (e.g.
  `make setup DISPLAY_LOCALE=en_GB.UTF-8`); documented in `make help` and the
  setup guide.

## [0.17.0] - 2026-07-01

### Added
- **`STATIC_IP` setup option** — bind an extra fixed IPv4 address to the
  Ethernet adapter *in addition* to DHCP, so the Pi stays reachable on
  networks with no DHCP server (a laptop patched straight in, a dumb switch, a
  field rig). `setup-kiosk.sh` gains a `configure_static_ip` step that owns a
  dedicated NetworkManager profile (`kiosk-static`, method `auto` + the static
  address, higher autoconnect priority than the stock `Wired connection 1`).
  The profile is recreated from scratch on every run so re-runs never stack
  addresses, and the change lands on the next reboot rather than bouncing the
  live SSH session. `STATIC_IP=none` removes a previously-added address.
  Exposed via `make setup`/`make provision`
  (`make setup STATIC_IP=192.168.50.1/24`); documented in `make help` and the
  setup guide. Empty/unset = DHCP only, so existing deployments are unaffected.

## [0.16.0] - 2026-06-29

### Added
- **`make provision`** — one command to take a fresh Pi end to end: it runs
  the four one-time steps in order (`setup` → `deploy` → `setup-web` →
  `volunteer-web-url`). The order is load-bearing — a fresh Pi has no canonical
  `/home/kiosk/display-pi` until `deploy` runs, and `setup-web` reads its
  install script from that path. Each step is invoked via a recursive `$(MAKE)`
  so the sequence holds even under `make -j`, and command-line overrides
  (`HOST`, `STREAM_KEY`, …) propagate to every step. Every step is idempotent,
  so re-running `provision` on an existing Pi is safe. `make help` now lists it
  under Bootstrap; `make setup` remains available for the base-kiosk step alone.

## [0.15.0] - 2026-06-28

### Added
- **Browser-based volunteer kiosk manager** (`web/kiosk_manager.py`). A
  minimal Flask single-page app (nginx → :5000) lets volunteers manage splash
  images and control the kiosk without any command-line skills. Features:
  upload (PNG/JPEG, exactly 1920×1080, ≤ 10 MB), delete, download, drag-and-
  drop or ↑↓ reorder, Restart Service, and Reboot Pi. Auth is a static token
  embedded in the URL; volunteers just double-click a shortcut file.
- **`install/kiosk-web-setup.sh`** — idempotent one-time setup: creates the
  `kiosk-web` system user, `/var/lib/kiosk-splash/` splash directory,
  `/opt/kiosk-web/` app + venv, `/etc/kiosk-web.conf` auth token, sudoers
  grant, and `kiosk-web.service`. Run once via `make setup-web`.
- **`make volunteer-web-url`** — reads the live token from the Pi and writes
  `volunteer-kiosk.webloc` (macOS) and `volunteer-kiosk.url` (Windows/Linux)
  shortcut files. Both are gitignored to keep the token out of version control.
- **`install/kiosk-web.service`** and **`install/kiosk-web.sudoers`** — systemd
  service definition and least-privilege sudoers grants for the `kiosk-web` user.
- **Splash images moved to `/var/lib/kiosk-splash/`** when the web manager is
  set up. `setup-kiosk.sh` seeds the directory from the repo's `images/splash.d/`
  on first run; `SPLASH_DIR` in `/etc/default/kiosk` directs `player.sh` to the
  new location. The legacy SSH volunteer path (`accept-splash` / splash-updater)
  is **superseded** — `SPLASH_DIR` now points away from `/home/kiosk/splash.d`,
  so the SSH pipeline no longer feeds the player.
- **Python unit tests** for `kiosk_manager.py` (`tests/test_kiosk_manager.py`,
  17 cases): `_strip_prefix` idempotency, token auth (missing/wrong/correct),
  upload validation (type, dimensions, size, filename sanitization), and reorder
  correctness/rejection. `tests/run-tests.sh` auto-creates a venv on first run.

### Fixed
- **`become-kiosk` helper was installed locally instead of on the Pi.** The
  `check_become_kiosk()` function in `deploy.sh` ran `sudo install` on the
  workstation (wrong machine), read from `dev/become-kiosk.sh` (wrong path),
  and was never called. Removed the dead function; added a remote SSH block
  that installs from `${REMOTE_DIR}/install/become-kiosk.sh` on the Pi.
- **Stored XSS via uploaded filename.** Uploaded filenames are now sanitized to
  `[A-Za-z0-9._-]` before being stored, preventing HTML injection when names are
  rendered in the management UI.
- **`systemctl --user restart` from a system service.** Added
  `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus` alongside
  `XDG_RUNTIME_DIR` in the restart subprocess call — required when running as a
  system daemon with no login session (see `become-kiosk.sh` incident 2026-06-13).

### Changed
- `deploy.sh` now updates `/opt/kiosk-web/kiosk_manager.py` and restarts
  `kiosk-web.service` when `/opt/kiosk-web/` exists on the target Pi.
- `install/nginx.conf` adds an HTTP server block on port 80 proxying to the
  Flask app. The rtmp-stat endpoint (localhost:8080) is unchanged.

> **Note:** On-device paths (nginx proxy, `systemctl --user` via kiosk-web
> service, reboot) are tested only by `make setup-web` and manual verification
> on real hardware. The unit tests above cover all pure-Python logic.

## [0.14.0] - 2026-06-27

### Changed
- **Hostname/IP watermark removed from the splash and live stream.** The mpv
  overlay used to paint the Pi's `hostname IP` in the bottom-left corner of
  every screen, so it sat permanently on top of the lobby splash and the live
  worship stream. That address now appears only where it's actually needed —
  the full-screen diagnostic/error screen (`render-status.sh`), which already
  reports Hostname and Network as status lines. The bottom-right health
  watermark (yellow WARN / red FAIL / gray STALE, hidden when OK) is unchanged
  and still shows on every screen so operators keep an at-a-glance
  "something's wrong" signal.
- **`health-monitor.sh` no longer writes the now-unused `ip`/`hostname` JSON
  fields** to `/tmp/kiosk-health.json`; the overlay no longer reads them. The
  file is back to the documented `{status, message, updated}` shape.

## [0.13.1] - 2026-06-23

### Fixed
- **`sshd-password-toggle.sh on/off` aborted with `tmp: unbound variable`.**
  Temp-file cleanup used `trap 'rm -f "$tmp"' RETURN`, but a RETURN trap is
  global and re-fires on every later function return — so when `main()`
  returned, the trap ran again with `$tmp` out of scope and `set -u` killed
  the script (after the drop-in was already written, but before the operator
  saw a clean exit). Replaced the trap with explicit `rm -f "$tmp"` right
  after the `install`. Added a regression test that forbids a RETURN trap in
  the script.

## [0.13.0] - 2026-06-23

### Added
- **SSH login by public key OR password, with a one-command toggle.**
  `setup-kiosk.sh` now installs `/etc/ssh/sshd_config.d/00-display-pi-auth.conf`
  so a fresh Pi accepts both auth methods out of the box. The new
  `install/sshd-password-toggle.sh` (`on` / `off` / `status`) flips password
  auth without hand-editing config, wrapped by `make ssh-password STATE=…`.
  The `00-` prefix makes the drop-in sort first, so it wins sshd's
  first-value-wins resolution over later drop-ins (e.g. rpi-imager's key-only
  file) and the stock `/etc/ssh/sshd_config`. Pubkey auth is always kept on, so
  `off` can't lock out key logins; the config is validated with `sshd -t` and
  applied with a `reload` (not `restart`), so the live SSH session survives a
  rejected config. See docs/setup-guide.md ("SSH password login").

## [0.12.1] - 2026-06-16

### Fixed
- **`make setup` no longer fails copying the splash image.** `create_splash`
  ran `sudo -u kiosk cp` to install `images/splash.png`, but the source lives
  under the SSH user's `0700` home (`display-pi-bootstrap/`), which the kiosk
  user can't traverse — so a fresh Pi setup aborted with
  `cp: cannot stat '.../images/splash.png': Permission denied`. The copy (both
  the default and the interactive picker branch) now runs as root via
  `install -o kiosk -g kiosk -m 0644`, which reads the source as root and
  hands the destination to the kiosk user atomically.

## [0.12.0] - 2026-06-16

### Fixed
- **Splash rotation now actually works.** Two bugs kept the kiosk stuck on
  one image: (1) `deploy.sh` gated the splash copy on a test that ran as
  the SSH user, who can't read the `0700 /home/kiosk` — so the rotation
  folder was never created on the Pi and the player fell back to the
  single `splash.png`; (2) once the folder existed as a symlink, `find`
  did not descend into it (a symlink start-point needs `-L`), so the
  player still saw an empty folder. `next_splash_image` now uses
  `find -L`, and the folder is provisioned by symlink (below).
- **Rotation cursor persists across restarts.** It was an in-memory
  counter that reset to the first slide on every service start, so
  `make restart` always showed image 0 instead of advancing. The cursor
  is now stored in `/home/kiosk/.splash-index`, so each splash entry —
  including after a restart or crash — steps to the next image.

### Changed
- **Splash images are symlinked, not copied.** `deploy.sh` now points
  `/home/kiosk/splash.d` and `/home/kiosk/splash.png` at the deployed
  repo (`images/…`), exactly like the `bin/` scripts — no more duplicate
  copies drifting out of sync, and the old copy blocks (which silently
  no-op'd due to the `0700` permission bug) are gone. The volunteer slide
  lives inside the symlinked folder and is protected from the deploy's
  `rsync --delete` by a top-level `--exclude='*-volunteer.png'`.
- **`setup-kiosk.sh`** no longer seeds a runtime `splash.d/` (deploy owns
  it via the symlink); it still installs the bootstrap `splash.png`
  fallback for the pre-deploy window.

### Removed
- Duplicate `images/rcc_splash.png` and `images/c242_splash.png` (the same
  images already ship in `images/splash.d/` as `01-rcc.png` / `02-c242.png`).

## [0.11.1] - 2026-06-16

### Added
- **`make restart`** — bounces the kiosk service without a full deploy.
  During testing this advances the splash rotation by one image (the
  player re-enters the splash loop on restart and picks the next slide).
  Uses the same password-free `sudo -u kiosk` path as `make deploy`, and
  resolves the kiosk UID on the Pi.

## [0.11.0] - 2026-06-16

### Added
- **Rotating splash.** The kiosk now cycles through the images in
  `/home/kiosk/splash.d/` whenever the stream is idle, **advancing one
  image each time the splash is (re)entered** — no timer, so the image
  only changes when the stream drops and the splash returns. New images
  are picked up at the next splash entry (or kiosk restart).
  - `install/player.sh`: new `SPLASH_DIR`/`SPLASH_IMAGE` env defaults
    (overridable via `/etc/default/kiosk`), an in-memory rotation cursor
    (`SPLASH_INDEX`), and a `next_splash_image()` picker that enumerates
    the folder (`sort -z`, deterministic) and advances in the **parent**
    shell — the `SPLASH_PID=$(show_splash)` subshell can't carry the
    cursor. `show_splash` now takes the image as an argument; its mpv
    flags and the `$(...)`-deadlock redirect are unchanged. Single-image
    folders still hold forever (no flicker); an empty folder falls back
    to the legacy `splash.png`, and a total absence is logged loudly
    rather than showing a blank screen.
  - `images/splash.d/`: new repo-side rotation source (seeded with the
    branded boards). `images/splash.png` remains the single fallback.
  - `dev/deploy.sh`: mirrors `images/splash.d/` → `/home/kiosk/splash.d/`
    as the kiosk user, `--exclude='*-volunteer.png'` so a deploy never
    wipes the volunteer slide.
  - `install/setup-kiosk.sh`: creates and seeds `/home/kiosk/splash.d/`
    (idempotent), and the generated bootstrap player rotates too.

### Changed
- **Volunteer splash-update now joins the rotation.**
  `install/install-staged-splash.sh` writes the validated upload to the
  fixed `/home/kiosk/splash.d/00-volunteer.png` (was `splash.png`).
  Repeat uploads overwrite it — latest wins, no stale buildup. The
  validator (`accept-splash.sh`) and the sudoers grant are unchanged.

## [0.10.0] - 2026-06-15

### Added
- **`create_splash()` installs a repo-shipped splash instead of always
  generating one.** On first setup (when `/home/kiosk/splash.png` does
  not yet exist) the source is chosen by precedence: (1) copy
  `images/splash.png` verbatim if present; (2) otherwise, if other
  images exist in `images/`, prompt the operator to pick one — guarded
  by a `-t 0` tty check so non-interactive runs don't hang; (3) fall
  back to the ImageMagick placeholder built from `$SPLASH_TEXT`. An
  existing `/home/kiosk/splash.png` is still left untouched.
- **`images/splash.png`** — the default placeholder ("Service will begin
  shortly", 1920×1080, white-on-black) now ships in the repo so a fresh
  setup gets a consistent splash without depending on the local font /
  ImageMagick rendering.

## [0.9.2] - 2026-06-13

### Fixed
- **`dev/splash-replace.ps1` — pause on interactive exit so the right-
  click "Run with PowerShell" window doesn't vanish before the
  volunteer reads the error.** Body wrapped in `try { … } finally { … }`;
  finally checks `[Console]::IsInputRedirected` and prompts for Enter
  only when stdin is interactive (no pipe), so automation/dev runs
  don't pause. Verified end-to-end on the Pi from a Windows test
  bundle: valid PNG accepted, all three error cases reject with rc=2
  and the documented friendly messages.

## [0.9.1] - 2026-06-13

### Added
- **`make volunteer-bundle`** — builds `volunteer-bundle.zip`
  containing the two client scripts, the README
  (`docs/volunteer-splash-update.md`), and the splash-updater private
  key pulled live from the Pi. One command to produce a hand-deliver
  bundle.

### Fixed
- **`.gitignore` — never commit `volunteer-bundle.zip` or stray key
  files.** The bundle contains a live SSH private key. Without an
  ignore rule, a routine `git add -A` would publish the key to the
  repo. Test pins the rules so a future cleanup of `.gitignore` can't
  silently re-open the gap.

## [0.9.0] - 2026-06-13

### Added
- **Splash-image update workflow for non-technical volunteers.** Three
  Pi-side scripts plus two client scripts (macOS/Linux + Windows) that
  let a volunteer replace `/home/kiosk/splash.png` over SSH with a hard
  guarantee that they can ONLY replace that one file.
  - `install/accept-splash.sh` — SSH `ForceCommand` target. Reads PNG
    from stdin, validates magic bytes, format (`identify` or `file -b`
    fallback), dimensions (must be 1920×1080), max size (10 MiB), and
    the trailing `IEND` chunk (catches truncated uploads that
    `identify` would otherwise accept — `identify` only parses IHDR).
    Stages to `/var/lib/splash-updater/staged.png`.
  - `install/install-staged-splash.sh` — root-only helper, invoked via
    a no-args `NOPASSWD:` sudo grant. Copies the staged PNG to
    `/home/kiosk/splash.png` and restarts the kiosk so the new image
    appears within ~2 seconds.
  - `install/splash-updater-setup.sh` — admin-run, one-time. Creates
    the `splash-updater` system user (locked password), generates an
    ed25519 keypair, writes `~splash-updater/.ssh/authorized_keys`
    with `restrict,no-port-forwarding,no-X11-forwarding,
    no-agent-forwarding,no-pty,command="…accept-splash"`, installs the
    sudoers entry, and prints the private key + connection details for
    the volunteer bundle.
  - `dev/splash-replace.sh` — macOS/Linux client. Validates PNG magic
    + 1920×1080 locally (so an obviously-wrong file fails fast with a
    clear message) then pipes the file via `ssh splash-updater@HOST`.
  - `dev/splash-replace.ps1` — Windows client. Uses `System.Drawing`
    for dimension check, shells out to `cmd /c "ssh … < file"` for
    binary-safe stdin redirection.

  Security model: SSH key auth only, `ForceCommand` traps every
  connection into the validator regardless of the client's intent.
  Worst case a malicious volunteer can do: replace `splash.png` with a
  valid 1920×1080 PNG (exactly what they're supposed to do). End-to-end
  verified on the live Pi: full PNG accepted, 100-byte truncated PNG
  rejected, shell attempts rejected, `scp` to arbitrary paths blocked,
  port forwards refused.

## [0.8.2] - 2026-06-13

### Fixed
- **`install/setup-kiosk.sh` — `backup_once` is finally actually once.**
  The function was creating a new timestamped backup on every `make
  setup` run, even when the file hadn't changed since the previous run.
  Three idempotent re-runs accumulated 19 redundant `.bak-<STAMP>`
  copies across cmdline.txt, config.txt, nginx.conf, watchdog.conf, and
  the kiosk logrotate config. The function now compares the live file
  against the most recent existing backup with `cmp -s` and skips when
  bytes match. After this change a new `.bak-<STAMP>` reliably means
  "this file actually changed."

  Also guards the `ls -1t .bak-*` glob with `|| true` so an empty
  match doesn't kill the script under `set -euo pipefail` (the
  pipefail variant of [the unmatched-glob-under-`-e` footgun][1]).

[1]: https://mywiki.wooledge.org/BashPitfalls#set_-e

## [0.8.1] - 2026-06-13

### Fixed
- **`install/setup-kiosk.sh` — drop `seat` from kiosk-user group loop.**
  Debian/Trixie has no POSIX `seat` group; seatd authenticates clients
  over a Unix socket via libseat instead, so the entry was speculative
  from day one and surfaced a benign `WARN: Group 'seat' does not exist
  on this system; skipping.` on every setup run. The kiosk user's
  remaining group memberships (`video render input audio`) cover DRM
  access, evdev input, and ALSA. No behavioral change beyond removing
  the noise.

## [0.8.0] - 2026-06-13

### Changed (BREAKING)
- **Rename `KIOSK_MODE`/`KIOSK_OUTPUT` → `HDMI_MODE`/`HDMI_OUTPUT`
  everywhere.** Removes the cross-layer name asymmetry — the value was
  already called `HDMI_MODE` at the workstation (`make setup
  HDMI_MODE=…`, `make hdmi-mode HDMI_MODE=…`) but became `KIOSK_MODE`
  inside `/etc/default/kiosk` and `player.sh`. Both names now match end
  to end. Affected files: `install/player.sh`, `install/setup-kiosk.sh`,
  `install/kiosk.service` (comment only), `dev/set-hdmi-mode.sh`,
  `diagnostics/render-status.sh`, `diagnostics/judder.sh`,
  `tests/run-tests.sh`. Migrating an existing Pi requires renaming the
  two lines inside `/etc/default/kiosk`:
      sudo sed -i 's/^KIOSK_MODE=/HDMI_MODE=/; s/^KIOSK_OUTPUT=/HDMI_OUTPUT=/' /etc/default/kiosk
      sudo systemctl --machine=kiosk@.host --user restart kiosk.service
  Fresh `make setup` runs write the new names directly. No
  backwards-compatibility shim; the rename is a clean cut.

## [0.7.0] - 2026-06-13

### Changed (BREAKING)
- **HDMI mode no longer written to `cmdline.txt`.** On Pi 5 / Trixie,
  the kernel `video=HDMI-A-1:<mode>` parameter synthesizes a CRT-style
  modeline that diverges from EDID-reported modes (e.g. kernel makes
  `1920x1080@30.00` while panel reports `1920x1080@30.003`). KMS lands
  on the synthesized mode; wayland (cage) lands on EDID-preferred; every
  atomic commit fails with `Invalid argument` → black screen and an
  unending stream of `connector HDMI-A-1: Atomic commit failed` lines in
  the journal.
  - `install/setup-kiosk.sh` now ALWAYS strips any stale
    `video=HDMI-A-1:*` token from cmdline.txt and never writes a new
    one. `HDMI_MODE` setup variable still flows through to
    `KIOSK_MODE=` in `/etc/default/kiosk`.
  - `dev/set-hdmi-mode.sh` same: strip on every run, never add.
  - `diagnostics/judder.sh tree` updated to teach the runtime-only path.

### Added
- **`install/player.sh` — `nearest_refresh_for` resolver.** wlr-randr's
  `--mode` rejects a target like `1920x1080@30` when the EDID-reported
  rate is `30.003000` (or any other non-integer). The resolver reads
  wlr-randr's mode list, matches the requested resolution, and picks
  the closest available refresh rate, then feeds that exact decimal back
  to `wlr-randr --mode`. Handles panels that report integer rates,
  panels that report 30.003/29.97, and panels that have no mode at the
  requested rate (returns empty → force_display_mode logs a WARN and
  leaves EDID-preferred active rather than fighting the panel).

## [0.6.4] - 2026-06-13

### Fixed
- **`install/become-kiosk.sh` — always own `XDG_RUNTIME_DIR` and export
  `DBUS_SESSION_BUS_ADDRESS`.** The helper had two bugs that surfaced
  together when verifying the post-install instructions on a Pi 5 / Trixie
  install:
  1. `XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u kiosk)}"`
     inherited the SSH caller's value (`/run/user/<deploy_uid>`), so
     `systemctl --user` connected to the deploy user's bus instead of
     kiosk's. The helper now overwrites unconditionally.
  2. The user-bus connection also needs `DBUS_SESSION_BUS_ADDRESS` set
     explicitly; without it `sudo -u kiosk -i` falls back to a lookup
     path that fails with "Operation not permitted". Derived from
     `XDG_RUNTIME_DIR` and forwarded via the existing SETENV grant.
- **`install/setup-kiosk.sh` post-install — journalctl reads system journal
  directly.** `become-kiosk journalctl --user` cannot read the journal
  because the kiosk user is not in `systemd-journal` group (and adding
  the group has broader implications). Switched to
  `sudo journalctl _SYSTEMD_USER_UNIT=kiosk.service -f`, which works
  unambiguously and surfaces the same log lines. Tests pin all three
  changes.

## [0.6.3] - 2026-06-13

### Fixed
- **`install/setup-kiosk.sh` post-install instructions — switch from
  `machinectl shell` / `journalctl -M kiosk@` to the project's
  `become-kiosk` helper.** `journalctl -M ${KIOSK_USER}@` failed on Pi OS
  with `Failed to open root directory of machine 'kiosk@'` because the
  kiosk user's `--user` systemd manager (running via linger) is not
  registered as a "machine" with `systemd-machined` — `-M user@` only
  works when machined knows about the user manager, which Pi OS does
  not arrange. `machinectl shell` worked because it opens an ephemeral
  session per invocation, but the asymmetry was a footgun. Both
  commands now use `become-kiosk`, which was added in 0.6.0 for
  exactly this purpose and works one-shot via `become-kiosk <cmd>`.
  Tests pin the new invocations and forbid the old `-M …KIOSK_USER@`
  form.

## [0.6.2] - 2026-06-13

### Fixed
- **`install/setup-kiosk.sh` — install `systemd-container` for `machinectl`.**
  The post-install instructions tell the operator to run
  `sudo machinectl shell ${KIOSK_USER}@ /bin/bash …` to inspect the kiosk
  user's `--user` systemd units, but Pi OS Lite does not ship `machinectl`
  by default. `install_packages()` now pins `systemd-container` so a fresh
  setup leaves the documented commands runnable. Test added.

## [0.6.1] - 2026-06-12

### Fixed
- **`install/setup-kiosk.sh` — Pi OS 13 (Trixie) package rename for `vcgencmd`.**
  Debian Trixie dropped `libraspberrypi-bin`; `vcgencmd` now ships in
  `raspi-utils`. A fresh `make setup` on a Pi 5 running Pi OS 13 failed at the
  apt-install step with "Package 'libraspberrypi-bin' has no installation
  candidate". `install_packages()` now probes `apt-cache show raspi-utils`
  and falls back to `libraspberrypi-bin` so the script works on both Bookworm
  and Trixie. `confirm_os` also accepts trixie alongside bookworm. Tests pin
  both package names and the apt-cache probe.

## [0.6.0] - 2026-05-31

### Changed
- **`install/player.sh` — promote `--video-sync=audio` from variant to default.**
  The previous `--video-sync=display-resample` resampled audio every video
  frame on the ATEM→Pi→ONN 4K stack and produced visible judder. The
  `audio-sync` variant offered via `judder.sh variant audio-sync` empirically
  eliminated it; this commit pins that flag as the default so a fresh deploy
  inherits the fix. Tests assert the flag is set and `display-resample` is
  not. See `docs/dev-journal/2026-05-31-audio-sync-default.md`.
- **`judder.sh variant` — explicit Enter-to-restore exit path.** Previously
  the command sat in `while true; do sleep 60; done` and relied on Ctrl-C
  triggering the EXIT trap; undiscoverable for a first-time operator and
  unreliable over flaky SSH. Now `read -r` blocks on a single line of input
  so Enter alone restores, and the on-screen instructions surface
  `./judder.sh restore` as a fallback for sessions that die before clean
  exit. Tests pin the new behavior.
- **`install/kiosk-deploy.sudoers` — broad NOPASSWD: ALL for the deploy
  user.** The narrow whitelist that grew during early development covered
  the deploy pipeline but not ad-hoc operations the operator routinely runs
  (`make hdmi-mode`, log fixups, package tweaks). Per the operator's
  explicit ask the deploy user now gets `ALL=(ALL) NOPASSWD: ALL`. The
  narrow rules below stay as documentation of the bare-minimum command set
  if the broad grant ever needs tightening.

### Added
- **`install/become-kiosk.sh`** — interactive helper that drops the deploy
  user into a `kiosk`-user login shell with `XDG_RUNTIME_DIR` set so
  `systemctl --user kiosk.service`, `wpctl`, and `journalctl --user-unit=…`
  work without "Failed to connect to bus" errors. Falls back to
  `/run/user/$(id -u kiosk)` when the caller has no `XDG_RUNTIME_DIR` (the
  common case for a fresh SSH login). Installed by `setup-kiosk.sh` to
  `/usr/local/bin/become-kiosk` so it's on PATH everywhere.

## [0.5.1] - 2026-05-31

### Fixed
- **`judder.sh` stat parser silently misreported "no active publishers".**
  In probe blocks where ffprobe simultaneously read full live-stream
  metadata, the embedded `ACTIVE PUBLISHERS (nginx-rtmp stat)` section
  printed `app=live: no active streams` with no raw XML retained — an
  operator had no way to distinguish "publisher genuinely transient" from
  "parser silently misread the XML". The XPath `app.findall('./live/stream')`
  was also brittle to namespaces and to bare-`<application>` XML shapes some
  nginx-rtmp builds emit. (Captured in `logs/monitor-5.log` from 2026-05-23
  and `docs/dev-journal/2026-05-31-stat-parser-blind-spot.md`.)

### Added
- **`diagnostics/parse_stat.py`** — shared XML parser (replaces two embedded
  Python heredocs in `judder.sh`). Prefers `defusedxml.ElementTree` (XXE /
  billion-laughs hardening), falls back to stdlib. Strips namespaces. Uses
  `.//stream` for nesting tolerance. Surfaces `<nclients>` when a `<live>`
  block has no `<stream>` so the operator can tell "publisher gone AND no
  subscribers" from "publisher gone BUT subscribers still waiting". Exits
  non-zero with stderr error on parse failure (no silent success).
- **`judder.sh probe`** now writes the raw stat XML to
  `/tmp/judder-stat-${TS}.xml` and prints the path. Future probe blocks
  that claim "no publishers" can be audited against the saved bytes.
- **`install/setup-kiosk.sh`** installs `python3-defusedxml` so the secure
  parser is always available on a fresh Pi.
- **Eight behavioral parser tests** in `tests/run-tests.sh` covering:
  standard XML, bare-`<application>` XML, key-mismatch, publisher-gone
  with subscribers waiting, subscribers-only, stream-key mode, malformed
  XML (exit 2), and namespaced root.

## [0.5.0] - 2026-05-24

### Added
- **`judder.sh rprobe` subcommand.** Rolling probe — the heavy `cmd_probe`
  dump is now opt-in via a separate subcommand instead of running
  unconditionally inside `monitor`'s loop. `monitor` keeps the original
  terse one-line-per-interval table; `rprobe` runs the same loop and
  appends a full probe dump after each tabular line, to both stdout and
  `/tmp/judder-monitor-<ts>.log`.

### Fixed
- **`judder.sh monitor` loop crashed silently on first iteration.** WIP
  changes parsed `vcgencmd get_throttled` and `vcgencmd measure_clock arm`
  at awk field `$3` (empty), so `arm=$((<empty>/1000000))` raised a bash
  arithmetic syntax error and `set -u` killed the loop before any data
  row was written — producing the header-only
  `/tmp/judder-monitor-<ts>.log` files seen on 2026-05-24. Reverted to
  field `$2` to match real `vcgencmd` output (`throttled=0xN`,
  `frequency(N)=<hz>`). Added a behavioral regression test that drives
  the parsing pipeline with shimmed device output.
- **`judder.sh` monitor/rprobe dispatch dropped the interval argument.**
  Dispatching as `cmd_monitor "BRIEF $@"` collapsed the mode flag and any
  trailing interval into a single quoted positional, so `./judder.sh
  monitor 5` always slept the 10s default. Now passes the flag as a
  separate arg (`cmd_monitor BRIEF "$@"`).

## [0.4.0] - 2026-05-16

### Added
- **Runtime HDMI mode enforcement via `wlr-randr`.** The boot-time kernel
  `video=HDMI-A-1:<mode>` parameter remains, but is now backed by a second
  authoritative layer running inside the cage session. `install/player.sh`'s
  new `force_display_mode()` reads `KIOSK_MODE`/`KIOSK_OUTPUT` from
  `/etc/default/kiosk` (sourced by `install/kiosk.service` via
  `EnvironmentFile=-`) and runs `wlr-randr --output … --mode …` before mpv
  launches. Fixes panels (e.g. cheap 4K TVs that advertise 3840x2160@30 as
  preferred) whose EDID overrides the kernel cmdline hint, causing 1080p
  sources to play back at 30Hz 4K with visible judder. See
  `docs/dev-journal/2026-05-16-judder-runtime-mode-enforcement.md`.
- **`/etc/default/kiosk` as the single source of truth for runtime mode.**
  `install/setup-kiosk.sh` (new `configure_runtime_mode()`) and
  `dev/set-hdmi-mode.sh` write `KIOSK_MODE=<value>` inside a
  `# === kiosk-setup BEGIN/END ===` marker block so re-runs replace cleanly.
  Operator entry points (`make setup HDMI_MODE=…`, `make hdmi-mode HDMI_MODE=…`)
  now update both `/boot/firmware/cmdline.txt` and `/etc/default/kiosk` in
  one shot.
- **`check_display_mode` row in `diagnostics/render-status.sh`.** Parses
  `wlr-randr`'s "(current)" line, compares against `KIOSK_MODE`, and emits
  `OK`/`WARN` so a mode mismatch surfaces on the kiosk status overlay
  without needing a probe run.
- Regression tests (static + behavioral wlr-randr stub) and operator
  playbook updates in `diagnostics/judder.sh tree` (Diagnosis A Option 2).

## [0.3.0] - 2026-05-10

### Added
- **`make set-time` — push the laptop's clock to the Pi over SSH.** Primary
  use case: offline venue where `systemd-timesyncd` has no upstream and the
  Pi (no RTC battery) has drifted off after a power cycle. Sends the laptop's
  Unix epoch (timezone-independent) so the Pi's wall clock reflects its own
  configured TZ correctly. Optional `TIME_OFFSET=<sec>` (decimal seconds
  accepted) adds to the laptop time to anticipate the SSH round-trip lag so
  the Pi's clock lands on the intended wall time, not OFFSET-seconds behind
  it. `date -s` is intentionally not in `install/kiosk-deploy.sudoers` (rare,
  root-level, worth a password gate); script reuses the
  `ssh -t` + command-arg recipe from `dev/set-hdmi-mode.sh` so the sudo
  prompt has a working PTY. Static and behavioral regression tests in
  `tests/run-tests.sh`.

## [0.2.2] - 2026-05-10

### Fixed
- **`make hdmi-mode` failed with `sudo: a terminal is required to read the
  password`.** `dev/set-hdmi-mode.sh` SSH-ed without `-t`, so the remote
  `sudo cp/tee` (writing `/boot/firmware/cmdline.txt`) had no `/dev/tty` to
  prompt against. Those writes are not in `install/kiosk-deploy.sudoers`
  (and shouldn't be — they're rare, root-level, and worth a password gate),
  so a real prompt is unavoidable. Two-part fix:
    1. `ssh -t` to allocate the remote PTY.
    2. Send the remote script as a base64-encoded command argument instead
       of via `bash -s <<<…`. Otherwise the here-string consumes local
       stdin (the user's keyboard) and the password prompt has no input
       source even with the PTY present.
  Regression tests in `tests/run-tests.sh`. See
  `docs/dev-journal/2026-05-10-set-hdmi-mode-sudo-tty.md`.

## [0.2.1] - 2026-05-10

### Fixed
- **`judder.sh monitor` drops counter crashed on a fresh/empty player log.**
  The previous `drops=$(grep -ci 'drop' "$PLAYER_LOG" 2>/dev/null || echo 0)`
  hit a GNU-grep quirk: `grep -c` on a no-match (incl. empty) file outputs
  `0` AND exits 1, so the `|| echo 0` fallback fired *in addition to* grep's
  own `0`, yielding a two-line `"0\n0"` value. The next line's arithmetic
  (`$((drops - start_drops))`) then failed with
  `syntax error in expression (error token is "0")` and aborted the monitor.
  Reproduced reliably on the Pi (GNU grep 3.x); not on the laptop (ugrep)
  — which is why the bug only showed up in venue use.
  Fix: assign the substitution unconditionally and fall back to `0` only when
  grep failed (missing file): `drops=$(grep -ci 'drop' "$PLAYER_LOG" 2>/dev/null) || drops=0`.
  Static + behavioral regression tests added in `tests/run-tests.sh` covering
  the three real input states (empty log, missing log, log with matches).

## [0.2.0] - 2026-05-09

### Added
- **`HDMI_MODE` is now a single source of truth.** `install/setup-kiosk.sh`
  reads the `HDMI_MODE` env var (e.g. `1920x1080@30`) and writes
  `video=HDMI-A-1:<MODE>` into `/boot/firmware/cmdline.txt` — the
  KMS-correct HDMI mode-forcing knob. `setup-kiosk.sh` is idempotent on
  re-runs: any prior `video=HDMI-A-1:*` token is stripped before the
  new one is added, so changing modes is a clean replace.
- **`dev/set-hdmi-mode.sh`** — new fix-script for an already-deployed
  Pi. SSHes in, backs up `cmdline.txt`, applies the same idempotent
  edit `setup-kiosk.sh` would, sanity-checks the file is exactly one
  non-empty line (cmdline.txt format errors brick boot), and prompts
  for reboot. Also warns if `config.txt` still contains inert legacy
  `hdmi_*` keys (it does not auto-edit them — the operator may have
  intentional non-kiosk config in there).
- **`make hdmi-mode HDMI_MODE=…`** target wraps the script. Examples:
  `make hdmi-mode HDMI_MODE=1920x1080@30`,
  `make hdmi-mode HDMI_MODE=none` to clear forcing.
- **`make setup` forwards `HDMI_MODE`** to the bootstrap, so a fresh
  Pi can be brought up with the right mode in one command:
  `make setup HDMI_MODE=1920x1080@30`.

### Changed
- **`judder.sh tree` Diagnosis A Option 2** now references the
  canonical mechanism (`make hdmi-mode HDMI_MODE=…`) instead of
  free-form recipe text. The manual `sudoedit cmdline.txt` recipe
  is kept as a fallback. This collapses the previous duplication
  between the tree text and the actual setup logic — no more
  recipe-drift regressions like 6aa7d4e.

### Operator notes
- Any Pi already deployed before 0.2.0 should run
  `make hdmi-mode HDMI_MODE=1920x1080@30` (or the appropriate mode
  for its display) once. This is non-destructive and idempotent.
- Inert `hdmi_group=`, `hdmi_mode=`, `hdmi_drive=`, `hdmi_enable_4kp60=`
  lines in `config.txt` are not auto-removed; remove them manually
  if they're confusing future readers. The repo-root `config.txt`
  (a snapshot from a deployed Pi) has been corrected as a reference.

### Versioning
- Minor bump (0.1.7 → 0.2.0): new public API surface (`HDMI_MODE`
  env var, `make hdmi-mode` target, `dev/set-hdmi-mode.sh` script).

## [0.1.7] - 2026-05-09

### Fixed
- **`judder.sh tree` HDMI mode-forcing recipe regressed back to legacy
  firmware knobs.** Commit `23c653c` (2026-05-02) had switched
  Diagnosis A Option 2 to the KMS-correct kernel `video=HDMI-A-1:1920x1080@30`
  parameter in `cmdline.txt`. Commit `6aa7d4e` (2026-05-03), which
  added the rtmp_stat / stream-key diagnostic infra, regenerated
  large parts of `judder.sh` and inadvertently reverted the recipe
  back to `hdmi_group=1` / `hdmi_mode=39` in `config.txt` — which
  Bookworm KMS silently ignores. Operator at venue followed the
  stale recipe, rebooted, and the 4K display kept upscaling.
  Recipe restored; two regression tests added (`assert_contains`
  for the cmdline.txt form, `assert_not_contains` for `hdmi_mode=39`)
  so the recipe can't silently revert again. See
  `docs/dev-journal/2026-05-09-hdmi-mode-regression.md`.

## [0.1.6] - 2026-05-09

### Added
- **`judder.sh stream-key` subcommand** and matching `make stream-key`
  target. Fast one-shot equivalent of the `ACTIVE PUBLISHERS` section
  from `probe`: prints one line per active publisher with the key,
  source IP, flashver, and an explicit `*** MISMATCH` tag when the
  publisher's key differs from the one the player subscribes to.
  Targeted at day-of-event triage when the kiosk is on splash and the
  operator needs a sub-second read on whether to fix the publisher or
  hot-edit `STREAM_URL` on the Pi. No deploy required (the diagnostic
  endpoint shipped in 0.1.5).

## [0.1.5] - 2026-05-03

### Added
- **nginx-rtmp HTTP stat endpoint** (`http://127.0.0.1:8080/stat`,
  localhost-only) and an `ACTIVE PUBLISHERS` section in
  `diagnostics/judder.sh probe` that parses it. When a publisher is
  connected to nginx but the player is stuck on splash, the probe now
  prints exactly which stream key is live and flags it
  (`*** MISMATCH: player expects key=restoration`). Closes the diagnostic
  gap that left the 2026-05-02 venue probe ambiguous (ESTAB on :1935 +
  `ffprobe: No such stream` — but no way to see which key was actually
  in use). See `docs/dev-journal/2026-05-03-stream-key-mismatch.md`.
  Tests added in `tests/run-tests.sh`. Requires `make deploy` to push
  the updated `nginx.conf` to the Pi.

### Fixed
- **Stale test assertions** for `--no-correct-pts` and `+genpts` in
  `tests/run-tests.sh`. Commit `26944db` ("trust source PTS")
  intentionally removed those mpv flags because they regressed
  smoothness on a clean 1080p30 ATEM feed; the asserts had been
  failing ever since. Inverted to `assert_not_contains` so the test
  suite captures the design decision instead of contradicting it.

## [0.1.4] - 2026-05-02

### Fixed
- **mpv hwdec falling back to software decode.** `install/player.sh`
  was passing `--hwdec=auto-safe`, which makes mpv walk the full
  hwdec ladder on each startup: CUDA → Vulkan → VDPAU → software.
  None of those exist on a Pi 4, so every probe failed noisily
  (`AVHWDeviceContext: Cannot load libcuda.so.1`,
  `VK_ERROR_INCOMPATIBLE_DRIVER`, `Failed to open VDPAU backend`)
  before mpv settled — and on a 1080p test stream the actual
  decode path landed in software, pegging mpv at 94% of one core
  and pushing the SoC to 77 °C. Pinned to `--hwdec=v4l2m2m-copy`
  (the Pi 4-native V4L2 H.264 decoder, already used by the
  bootstrap heredoc in `install/setup-kiosk.sh`). Live test on
  1080p30→1080p60 dropped mpv CPU to 36% and temp to 56 °C.
  Tests added in `tests/run-tests.sh`.

## [0.1.3] - 2026-05-02

### Fixed
- **Missing operational dependencies in `install_packages`.** Several
  scripts in `install/` and `diagnostics/` shell out to commands that
  Raspberry Pi OS Lite doesn't ship by default. `nc`
  (`netcat-openbsd`) is the most critical: `player.sh`'s
  `wait_for_nginx` gate, `healthcheck.sh`, `assess.sh`, and
  `render-status.sh` all use it; without it the kiosk hangs at boot on
  a fresh-`make setup` Pi. `wlr-randr`, `kmsprint`
  (`libdrm-tests`), `vcgencmd` (`libraspberrypi-bin`), and `aplay`
  (`alsa-utils`) are now also pinned for the on-Pi `judder.sh`
  triage toolkit and audio fallbacks. Tests added in
  `tests/run-tests.sh`.
- **Stale `docs/journal/` path references.** Renamed dev-journal
  directory to `docs/dev-journal/`; updated all references in
  `tests/run-tests.sh`, `dev/deploy.sh`, `install/setup-kiosk.sh`
  comments, `docs/setup-guide.md`, and `CHANGELOG.md`.

## [0.1.2] - 2026-04-25

### Fixed
- **`make deploy` password prompt.** `/home/kiosk` is mode 0700, so the
  deploy user (rpi) could not read either side of the `kiosk.service`
  diff in `dev/deploy.sh`. The diff always exited 2, the script always
  fell through to `sudo cp …kiosk.service`, and that exact command was
  never in the sudoers whitelist — sudo prompted and the deploy aborted.
  Now runs both the diff and the cp via `sudo -u kiosk`, leveraging the
  existing `(kiosk) NOPASSWD: ALL` grant. As a bonus the diff is finally
  accurate, so the service file is only re-copied when it actually
  changed. Tests added in `tests/run-tests.sh`.

## [0.1.1] - 2026-04-25

### Fixed
- **HDMI 0 audio.** mpv now routes audio directly to the vc4-hdmi-0 ALSA
  device (`alsa/plughw:CARD=vc4hdmi0,DEV=0`) instead of relying on PipeWire's
  default-sink selection, which was picking the bcm2835 analog/mailbox
  fallback. Applies to both `install/player.sh` and the bootstrap heredoc
  in `install/setup-kiosk.sh`. See
  `docs/dev-journal/2026-04-25-hdmi-audio-routing.md`.

### Added
- `install/wireplumber-hdmi-default.conf` — reference WirePlumber rule
  that pins HDMI as the system-wide default sink. Not auto-installed;
  kept as an escape hatch for switching to PipeWire-mediated routing.
- `install/kiosk-deploy.sudoers` + `setup-kiosk.sh: configure_deploy_sudoers()`
  — narrow sudoers whitelist for the SSH/deploy user, so `make deploy`
  no longer needs a password every run. Bootstrap an existing Pi with
  `make sudoers` (one-time, interactive). Documented in the journal.
- `make sudoers` Makefile target.
- `docs/dev-journal/` — first dev journal entry documenting the HDMI audio
  routing decision (option A vs B) and the deploy sudoers whitelist.
- `CHANGELOG.md` and `VERSION` — versioning baseline.

### Changed
- `dev/deploy.sh`: dropped the `sudo -A` / `ssh -A` flags introduced
  during the abandoned askpass attempt; option 2 (sudoers whitelist)
  makes them unnecessary.

## [0.1.0] - prior to 2026-04-25

Baseline covering everything up through commit `785604d`
("feat(overlay): add bottom-left hostname+IP corner overlay"):

- RTMP-driven kiosk on Pi 4 (cage + mpv + nginx-rtmp).
- Splash-on-idle, auto-switch to live stream, auto-recover via systemd.
- Boot assessment + diagnostics rendered to HDMI on startup.
- Persistent HDMI health overlay (mpv Lua + health-monitor daemon).
- Hostname/IP corner overlay.
- Hardware watchdog, log rotation, healthcheck cron.
- PipeWire client.conf bootstrap for the kiosk user.
