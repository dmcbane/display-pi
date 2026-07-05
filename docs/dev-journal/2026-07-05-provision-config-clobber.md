# Provision discards custom settings (stream key, static IP, status board blind)

**Date:** 2026-07-05
**Status:** Fixed in v0.24.0 (commit 8e8b352); verified live end-to-end
**Affects:** `Makefile`, `install/setup-kiosk.sh`, `install/player.sh`,
`install/nginx.conf`, `install/render-nginx-conf.sh` (new), `dev/deploy.sh`,
`diagnostics/render-status.sh`, `diagnostics/judder.sh`, `web/kiosk_manager.py`

Field notes from a fresh-Pi provision that only worked with default settings.
Four symptoms, one theme: setup and deploy each thought they owned the
configuration, and deploy always won.

## 1. Custom STREAM_KEY silently discarded

Provisioned a fresh Pi OS Lite (64-bit) install with:

```
make provision STREAM_KEY=church242 STATIC_IP=192.168.0.106/16 HOST=displaypi
```

Could not stream to the Pi afterwards — the player, both diagnostics, and the
web manager all still referenced the default key (`live/restoration`).

**Root cause:** provision fought itself. Step 1 (`setup`) baked STREAM_KEY
into a *generated* `/home/kiosk/bin/player.sh`; step 2 (`deploy`) replaced
that file with a symlink to the repo's `install/player.sh`, which hardcoded
`rtmp://127.0.0.1/live/restoration`. The diagnostics and web manager carried
their own hardcoded copies of the default.

**Fix:** `/etc/default/kiosk` is now the single persistent config store.
`setup-kiosk.sh` writes `STREAM_KEY` / `RTMP_APP` / `STREAM_URL` / `VOLUME` /
`RTMP_ALLOW_PUBLISH_CIDRS` there; `kiosk.service` loads it via
`EnvironmentFile=`; `player.sh`, `render-status.sh`, `judder.sh`, and
`kiosk_manager.py` all read it (env wins, then the file, then the default).
Deploy never touches the file.

**Verified:** mpv playing `rtmp://127.0.0.1/live/church242` on HDMI from a
live test stream.

## 2. Static IP "has no gateway and can't be accessed"

The missing gateway was a red herring.

**Root cause:** `kiosk-static` was never *active*. Setup creates the profile
"applies on next reboot", and a re-provision (14:24, after the 14:17 boot)
deleted and recreated it inactive — so the Pi never answered at 192.168.0.106
at all. The gateway hand-added in nmtui (192.168.0.1) doesn't exist on the
home LAN (192.168.1.0/24) and would have poisoned the default route.

**Fix (on the Pi):** removed the bogus gateway, activated the profile. The Pi
answers at both 192.168.1.172 (DHCP) and 192.168.0.106 (static, direct-reach,
no gateway — DHCP owns the routes).

**Fix (in the repo):** new `STATIC_GATEWAY=` / `STATIC_DNS=` setup vars for
when the static address is the Pi's primary identity on a DHCP-less network;
setup output and docs/setup-guide.md now say how to activate immediately
(`sudo nmcli connection up kiosk-static`) instead of waiting for a reboot.

**Note:** a machine on 192.168.1.0/24 still can't reach 192.168.0.106 without
a host route — that's routing on the connecting side, not a Pi
misconfiguration. On the church LAN (192.168.0.0/24) it works directly.

## 3. Web manager blind to the stream key and connected publishers

Two causes.

**Cause A:** `kiosk_manager.py` hardcoded the default URL and had no
publisher view. **Fix:** the status board now shows a "Player Stream" row
(key + URL read fresh from `/etc/default/kiosk`) and one "Publisher" row per
stream connected to nginx-rtmp (key, source IP, Mb/s from the loopback
`rtmp_stat` endpoint). A publisher pushing the wrong key shows WARN naming
the expected key. Verified live: wrongkey push →
`WARN live/wrongkey … (player expects church242)`.

**Cause B (deeper — also affected playback):** nginx `worker_processes auto`.
nginx-rtmp keeps stream state *per worker*, so with 4 workers on a Pi 4 the
publisher landed on one worker while `/stat` queries and mpv subscriptions
hit random others. The board missed publishers ~3/4 of the time and
splash→stream switching was a retry lottery. **Fix:** `worker_processes 1`
(plenty for one stream + the proxied web manager); `/stat` is now
deterministic.

## 4. Override or keep-existing? (it was a mix of both)

**Fix:** explicit-override-wins, keep-existing-otherwise semantics
everywhere:

- `make setup` forwards only variables explicitly set on the command line or
  environment (`$(origin)` check in the Makefile); anything not passed keeps
  its persisted value from `/etc/default/kiosk`. Verified: a bare
  `make setup` re-run kept `STREAM_KEY=church242`.
- setup and deploy both render nginx.conf from `install/nginx.conf` via the
  new `install/render-nginx-conf.sh` (substituting the persisted `RTMP_APP` +
  allow-publish CIDRs), so a deploy can no longer revert values configured at
  setup time.
- the bootstrap player generator now replaces a deploy-installed symlink
  instead of writing through it into the deployed repo copy (tee follows
  symlinks).

No version-tracking machinery was needed: `/etc/default/kiosk` is the one
source of truth, setup only changes the keys you explicitly pass, and deploy
never writes config at all.
