# RTMP push accepted but kiosk stays on splash

Date: 2026-04-25

## Symptom

`make setup` succeeded on a fresh Pi, splash showed correctly, but pushing
an RTMP stream to `rtmp://<pi>/live/<key>` from a workstation never caused
the kiosk to switch off the splash. nginx access log showed the PUBLISH
arriving and lasting tens of seconds, plus brief 1–2 second PLAY entries
from 127.0.0.1.

## Root cause

`make setup` writes an inline `player.sh` from `install/setup-kiosk.sh` whose
liveness check was `timeout 3 ffprobe -show_streams ...`. On the Pi, RTMP
handshake + ffprobe's default `analyzeduration` (5s) means the first
`codec_type` line typically appears 4–7 seconds in. The 3s cap killed
ffprobe (exit 124) every time, so `stream_live()` always returned false
and the loop never advanced past the splash.

Verified live (stream publishing, run on the Pi):

- `timeout 3  ffprobe -show_streams ...` → exit 124, no output
- `timeout 10 ffprobe -show_streams ...` → exit 0, full stream info

## Fix

Two layers:

1. The repo's `install/player.sh` (the real one, symlinked in by
   `make deploy`) already used `timeout 10` and a tighter
   `-show_entries stream=codec_type` query. Running `make deploy`
   replaces the inline template with the symlink and the kiosk works.
2. Defense-in-depth: bumped the inline template in
   `install/setup-kiosk.sh` to `timeout 8` plus
   `-analyzeduration 1500000 -probesize 500000`, so a setup-only Pi
   (no deploy yet) still detects streams.

## Why this is a sharp edge

`make setup` produces a working-but-minimal kiosk; `make deploy` is what
gives you the full feature set (assess, diagnostics, health overlay).
A fresh-Pi flow that runs `setup` and stops there will look broken in
non-obvious ways. Long-term cleanup: have setup-kiosk.sh symlink to
`install/player.sh` instead of generating its own copy.
