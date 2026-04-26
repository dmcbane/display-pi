# Changelog

All notable changes to display-pi are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-04-25

### Fixed
- **HDMI 0 audio.** mpv now routes audio directly to the vc4-hdmi-0 ALSA
  device (`alsa/plughw:CARD=vc4hdmi0,DEV=0`) instead of relying on PipeWire's
  default-sink selection, which was picking the bcm2835 analog/mailbox
  fallback. Applies to both `install/player.sh` and the bootstrap heredoc
  in `install/setup-kiosk.sh`. See
  `docs/journal/2026-04-25-hdmi-audio-routing.md`.

### Added
- `install/wireplumber-hdmi-default.conf` — reference WirePlumber rule
  that pins HDMI as the system-wide default sink. Not auto-installed;
  kept as an escape hatch for switching to PipeWire-mediated routing.
- `install/kiosk-deploy.sudoers` + `setup-kiosk.sh: configure_deploy_sudoers()`
  — narrow sudoers whitelist for the SSH/deploy user, so `make deploy`
  no longer needs a password every run. Bootstrap an existing Pi with
  `make sudoers` (one-time, interactive). Documented in the journal.
- `make sudoers` Makefile target.
- `docs/journal/` — first dev journal entry documenting the HDMI audio
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
