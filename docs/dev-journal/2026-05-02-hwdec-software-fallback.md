# mpv `--hwdec=auto-safe` falls back to software decode on Pi 4

**Date:** 2026-05-02
**Status:** Active
**Affects:** `install/player.sh`

## Symptom

Live RTMP playback ran with mpv pegged at ~95% of one ARM core and SoC
temp 75–77 °C inside a few minutes. `judder.sh probe` consistently showed
this trio in the player log right after each mpv launch:

```
[ffmpeg] AVHWDeviceContext: Cannot load libcuda.so.1
[ffmpeg] AVHWDeviceContext: Could not dynamically load CUDA
[ffmpeg] AVHWDeviceContext: Instance creation failure: VK_ERROR_INCOMPATIBLE_DRIVER
Failed to open VDPAU backend libvdpau_nvidia.so: ...
```

## Root cause

`install/player.sh` was passing `--hwdec=auto-safe`. mpv's `auto-safe`
chain walks every hwdec backend it was compiled with:

```
cuda-copy → vulkan → vdpau-copy → vaapi-copy → drm-copy → v4l2m2m-copy → no
```

On a Pi 4 (vc4-kms-v3d, no Nvidia, no VAAPI driver, no Vulkan ICD), the
first four all fail. mpv prints the error for each and continues. The
choice it lands on is *not* a Pi 4-native path — it falls through to
software decode for live RTMP. (Confirmed by `top`: 94.7% CPU on one
core for a 1080p30 source.)

The bootstrap heredoc-generated player in `install/setup-kiosk.sh`
already used the right thing — `--hwdec=v4l2m2m-copy`, the V4L2 m2m
H.264 decoder backed by the Pi 4 SoC's hardware H.264 block. The
deployed `install/player.sh` (the one `make deploy` symlinks into
place) had `auto-safe` from day one.

## Fix

Pin both player.sh files to the explicit Pi-native decoder:

```
--hwdec=v4l2m2m-copy
```

## Verification

Live test on a 1080p30 ffmpeg testsrc against a 1080p60 monitor:

| Metric        | Before (auto-safe) | After (v4l2m2m-copy) |
|---------------|--------------------|----------------------|
| mpv CPU       | 94.7%              | 36.4%                |
| SoC temp      | 77 °C              | 56 °C                |
| Init log      | 4 hwdec error lines| clean                |
| Drop/miss     | (sporadic)         | 0                    |

A real ATEM feed at full motion will sit higher than testsrc, but the
hardware decoder caps the cost predictably; software decode does not.

## Lesson

Don't trust `auto-safe` on embedded targets. Pick the decoder
explicitly when the platform is known. The mpv probe noise was the
loud-but-harmless symptom; the silent failure (software fallback) was
the actual bug.
