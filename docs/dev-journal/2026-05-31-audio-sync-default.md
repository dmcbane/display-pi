# `--video-sync=audio` becomes the default

**Date:** 2026-05-31
**Status:** Fixed
**Affects:** `install/player.sh`, `tests/run-tests.sh`

## Symptom

Live playback on the kiosk exhibited persistent visible judder — micro-stutter
roughly every couple of seconds — even after HDMI mode enforcement landed
(commit 33ff4be) and the display was confirmed at 1920x1080@30. Source frame
rate from the ATEM Mini Pro matched the display exactly (30/1), so a
timing-mismatch explanation didn't fit.

## Root cause

`mpv --video-sync=display-resample` resamples *audio* to match the display's
exact refresh rate so the video clock can run on the display's vblank without
drifting against audio. On the ATEM→Pi→ONN 4K stack the audio resampling
itself was burning enough CPU per frame to cause the player to miss vblank
deadlines, producing the judder. Same hardware, same source, same display
mode — but with `--video-sync=audio` (mpv's actual default; the video clock
follows audio and frames are duplicated/dropped as needed) the judder
disappears.

This was confirmed empirically using the existing `judder.sh variant
audio-sync` A/B harness over multiple sessions before promoting it.

## Fix

Pin `--video-sync=audio` as the default in `install/player.sh`. Tests assert
the new flag is present and that `--video-sync=display-resample` is *not*,
so a future "fix" can't silently regress us back.

The `judder.sh` `audio-sync` variant entry remains in the list — it's now a
no-op against the baseline player but keeps the A/B harness symmetrical with
the other variants (`vdrop`, `no-resample`, etc.) for future investigations.

## Follow-up notes

- If a future panel/source combination ever needs frame-perfect timing
  (e.g. a panel that hates dropped frames), `display-resample` remains
  available via `judder.sh variant no-resample` (which drops the flag
  entirely) or by editing player.sh directly.
- `--video-sync=audio` is mpv's documented default — pinning it explicitly
  is for clarity and to anchor the test assertion. Reading player.sh in
  isolation should make the choice obvious without consulting mpv docs.
