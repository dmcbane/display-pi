# Deploy: stale diffs cause silent re-copy on every run

**Date:** 2026-04-25
**Status:** Deferred — known issue, fix planned
**Affects:** `dev/deploy.sh` (logrotate, PipeWire client.conf, splash.png blocks)

## Symptom

Every `make deploy` reprints "logrotate config updated" and "PipeWire
client.conf installed", even when nothing in those files changed. Same
pattern would apply to the splash.png block whenever a splash exists.
Functionally correct (`cp` is idempotent), but cosmetically noisy and
wastes a little I/O per deploy.

## Cause

Same root cause as the `kiosk.service` password-prompt bug fixed in
0.1.2: `/home/kiosk` is mode 0700, so the deploy user (rpi) cannot read
files under it. The bare `diff -q` and `[[ -f ... ]]` existence checks
in `dev/deploy.sh` therefore return non-zero **regardless of whether
the file actually differs**, and the script falls through to the cp
branch every time. For these blocks the destination cp commands *are*
in the sudoers whitelist, so the failure stays silent — the deploy just
re-copies needlessly.

Affected blocks in `dev/deploy.sh` (as of 0.1.2):

- **logrotate** (~L62): `diff -q .../install/logrotate-kiosk /etc/logrotate.d/kiosk-player`
  — source side is unreadable to rpi.
- **PipeWire client.conf** (~L69): `[[ ! -f /home/kiosk/.config/pipewire/client.conf ]]`
  — rpi cannot stat into /home/kiosk, so the file always appears missing.
- **splash.png** (~L114): `diff -q .../images/splash.png /home/kiosk/splash.png`
  — both sides unreadable to rpi.

The healthcheck-cron block (~L81) uses `sudo diff` against a root-owned
file, so it works correctly. The `kiosk.service` block was fixed in 0.1.2.

## Fix shape (when we get to it)

Same pattern as the 0.1.2 fix: run the readability-sensitive commands
under `sudo -u kiosk`, leveraging the existing `(kiosk) NOPASSWD: ALL`
grant. For each affected block:

- `diff -q SRC DST` → `sudo -u kiosk diff -q SRC DST`
- `[[ -f /home/kiosk/... ]]` → `sudo -u kiosk test -f /home/kiosk/...`
- For destinations the kiosk user owns (PipeWire client.conf, splash.png):
  drop the `sudo cp` in favor of `sudo -u kiosk cp`, and prune the now-
  unused entries from `install/kiosk-deploy.sudoers`. logrotate-kiosk
  lives in /etc and stays as `sudo cp`.

Add tests in `tests/run-tests.sh` mirroring the three added in 0.1.2.
Bump to 0.1.3 (patch — fix, no behavior change for users).

## Why deferred

Cosmetic only — `make deploy` works correctly and idempotently today.
Bundling all three blocks into one commit is cleaner than piecemeal,
and there's no urgency since 0.1.2 unblocked the actual user-visible
failure (password prompt).
