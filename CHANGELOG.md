# Changelog

All notable changes to display-pi are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  (`*** MISMATCH: player expects key=church242`). Closes the diagnostic
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
