# HDMI Audio Routing — pin mpv to vc4-hdmi-0 (bypass PipeWire)

**Date:** 2026-04-25
**Status:** Active
**Affects:** `install/player.sh`, `install/setup-kiosk.sh`

## Symptom

No audio from HDMI 0 on the kiosk Pi during a live RTMP stream. Video was
fine. The HDMI sink in the receiver was on the right input and not muted.

## Diagnosis

Hardware was healthy:

- `aplay -l` showed both `vc4hdmi0` (HDMI-A-1, connected) and `vc4hdmi1`
  (HDMI-A-2, disconnected). The kiosk user was in the `audio` group.
- `/sys/class/drm/card?-HDMI-A-1/status` reported `connected`.
- `amixer -c vc4hdmi0` returned no controls — that is **expected** for the
  upstream `vc4-hdmi` driver. All volume/mute is digital, upstream of ALSA.

The fault was in the routing stack. With `pipewire`, `pipewire-pulse`, and
`wireplumber` running, mpv's `--audio-device=auto` selects the PipeWire AO
in preference to raw ALSA. WirePlumber's `wpctl status` showed:

```
 ├─ Sinks:
 │      35. Built-in Audio Digital Stereo (HDMI) [vol: 0.40]
 │  *   68. Built-in Audio Stereo               [vol: 0.40]
```

The `*` marks the default sink — sink #68, which is the bcm2835
mailbox/fallback (the analog 3.5mm jack, with nothing plugged in). mpv was
sending audio to PipeWire, PipeWire was routing to its default sink, the
default sink was the analog jack, and the audio went into the void.

WirePlumber's default-sink ranking is deterministic but not what we want
on this kiosk: the `stereo-fallback` sink it picks is the bcm2835 mailbox,
not HDMI.

## Decision

**Option A (active fix):** mpv talks directly to ALSA, pinned to the HDMI-0
card by name. In `install/player.sh`:

```
--audio-device=alsa/plughw:CARD=vc4hdmi0,DEV=0
```

`plughw` (not `hw`) is intentional: it routes through ALSA's plug layer so
sample-rate or format mismatches get auto-converted instead of failing the
open. `CARD=vc4hdmi0` (not a numeric index) survives kernel-driver load
order changes.

The same change is applied to the bootstrap `player.sh` heredoc inside
`install/setup-kiosk.sh` so a fresh `setup-kiosk.sh` run on a new Pi
produces a working baseline before `dev/deploy.sh` overlays the full
script.

## Alternatives considered

**Option B (staged, not active):** Leave mpv on `--audio-device=auto` and
fix WirePlumber's default-sink choice with a config file that bumps the
HDMI sink's priority. This keeps PipeWire in the audio path, which would
matter if we ever want to mix multiple audio sources or apply per-app
routing.

The reference config is checked in at `install/wireplumber-hdmi-default.conf`
with manual installation instructions in its header comment. It is not
auto-installed by `setup-kiosk.sh`.

To switch from A to B in the future:

1. Revert `--audio-device=alsa/plughw:CARD=vc4hdmi0,DEV=0` back to
   `--audio-device=auto` in `install/player.sh` (and the heredoc).
2. Install `install/wireplumber-hdmi-default.conf` as
   `~kiosk/.config/wireplumber/wireplumber.conf.d/50-hdmi-default.conf`.
3. Restart wireplumber for the kiosk user.
4. Verify with `wpctl status` that the HDMI sink is now marked default.

**Option C (rejected):** Uninstall PipeWire entirely. Out of scope — the
`assess.sh` boot probe queries PipeWire to confirm an audio sink exists,
and removing it would force a refactor of the diagnostics path. Not worth
the churn.

## Consequences

- Audio is now deterministic. No matter what WirePlumber decides at session
  start, mpv goes straight to vc4-hdmi-0.
- The kiosk no longer depends on PipeWire for audio playback. PipeWire is
  still installed and running (for the assess.sh probe and as the option-B
  escape hatch), but it is not in the hot path.
- If the HDMI cable, receiver, or downstream device is changed and EDID
  re-negotiates a different sample rate, `plughw` will adapt rather than
  drop audio. `hw:` (the strict variant) would not.
- The `vc4hdmi0` name is hard-coded. On a Pi where HDMI-1 is the active
  output (e.g. the second HDMI port on a Pi 4), this would need to become
  `vc4hdmi1`. We accept this trade-off because every kiosk in the fleet
  uses HDMI 0; an HDMI-1 deployment would be a configuration knob worth
  adding then, not now.

## How to validate after a change in this area

```
# On the Pi, as the kiosk user:
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 \
  speaker-test -c 2 -t sine -f 440 -D plughw:CARD=vc4hdmi0,DEV=0 -l 1

# During a live stream, confirm mpv opened the right device:
grep -i 'AO\|audio' /tmp/player.log | tail
```

If the speaker test produces a tone and mpv's logs show ALSA AO opening
`plughw:CARD=vc4hdmi0,DEV=0`, the path is correct.

---

## Addendum: deploy sudoers whitelist (same commit)

Trying to deploy this audio fix surfaced a separate issue: `dev/deploy.sh`
needed an interactive sudo password on the Pi for every run, because the
prior assumption of "passwordless sudo on the Pi" was wrong (the memory
was stale). An attempt to wire up `sudo -A` with an askpass helper would
have required a Pi-side askpass that could fetch the password from the
workstation — non-trivial.

**Decision:** narrow `sudoers.d` whitelist instead. We added
`install/kiosk-deploy.sudoers` containing:

- `(kiosk) NOPASSWD:SETENV: ALL` — becoming the unprivileged kiosk user
  is unrestricted; `SETENV` is required so the deploy can pass
  `XDG_RUNTIME_DIR` through to `systemctl --user`.
- `(root) NOPASSWD: KIOSK_FILE_OPS, KIOSK_SERVICE_OPS` — each root
  command is pinned to its specific source-and-destination paths
  (e.g. `/usr/bin/cp /home/kiosk/display-pi/install/nginx.conf
  /etc/nginx/nginx.conf`), not wildcarded.

The `__DEPLOY_USER__` placeholder in the file is substituted at install
time so the same file works for any SSH username.

**Bootstrap paths:**

- Fresh Pi: `setup-kiosk.sh`'s `configure_deploy_sudoers()` validates
  with `visudo -cf` and installs to `/etc/sudoers.d/kiosk-deploy` at
  mode 0440.
- Existing Pi: `make sudoers` does the same in one interactive command
  (one password prompt, then deploys are passwordless forever after).

**Why this is a UX shortcut, not a security boundary:** the deploy user
already has SSH/shell on the Pi. The whitelist removes friction; it does
not contain a compromised account. If the deploy user is compromised, an
attacker can do everything in the whitelist without authenticating —
that's the same level of access they would have via plain shell anyway.
