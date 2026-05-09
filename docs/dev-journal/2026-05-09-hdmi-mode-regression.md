# HDMI mode-forcing recipe regressed in judder.sh tree (config.txt vs cmdline.txt)

**Date:** 2026-05-09
**Status:** Fixed (recipe restored, regression test added)
**Affects:** `diagnostics/judder.sh` (tree text), `tests/run-tests.sh`

## Symptom

Operator at venue saw 1080p30 RTMP source upscaled to 4K@30 on a 4K
display through cage/Wayland; mpv pegged at ~28% CPU with persistent
judder. Followed the recipe in `judder.sh tree` (Diagnosis A, Option 2)
which said:

```
sudoedit /boot/firmware/config.txt
  hdmi_group=1
  hdmi_mode=39        # 1920x1080 @ 30 Hz CEA
```

After reboot, `wlr-randr` and `kmsprint` still reported the display at
`3840x2160 @ 30Hz (current)`. The legacy firmware knobs had been
silently ignored.

## Root cause

Two layers:

1. **The script-text regression.** Commit `23c653c` (2026-05-02)
   originally fixed this exact gotcha by switching the recipe to the
   KMS-correct `cmdline.txt` form (`video=HDMI-A-1:1920x1080@30`).
   Commit `6aa7d4e` (2026-05-03), which added the rtmp_stat / stream-key
   diagnostic infra, regenerated a large portion of `judder.sh` and
   inadvertently reverted the recipe back to the legacy `hdmi_group=` /
   `hdmi_mode=` form. No test caught the revert because nothing in the
   suite asserted the recipe's content. `git blame` lays the blame
   squarely on the rtmp_stat commit.

2. **The underlying gotcha.** Under Bookworm 64-bit with `dtoverlay=vc4-kms-v3d`
   (the modern KMS driver, which we do use — see `disable_fw_kms_setup=1`
   in `config.txt`), the firmware-era HDMI knobs in `config.txt`
   (`hdmi_group`, `hdmi_mode`, `hdmi_drive`, `hdmi_enable_4kp60`, etc.)
   are *parsed but not applied*. Mode selection moves to the kernel
   DRM driver, which honours the `video=` kernel parameter.

## Fix

1. Restored the cmdline.txt recipe text in `judder.sh tree`,
   Diagnosis A Option 2.
2. Added two regression tests in `tests/run-tests.sh`:
   - `assert_contains` for `video=HDMI-A-1:1920x1080@30`
   - `assert_not_contains` for `hdmi_mode=39`
   These guard against future revert-by-rewrite.

## Operator remediation (to apply now)

```
# 1. Remove the inert lines from config.txt (optional but tidy):
sudoedit /boot/firmware/config.txt
#    delete the hdmi_group=1 / hdmi_mode=39 lines

# 2. Append the kernel video= token to cmdline.txt (single line!):
sudoedit /boot/firmware/cmdline.txt
#    append:  video=HDMI-A-1:1920x1080@30
#    (cmdline.txt is ONE line, space-separated tokens — do not add a newline)

# 3. Reboot, then verify:
sudo reboot
# After it comes back:
make judder-probe
# kmsprint should show:  Crtc 3 (100) 1920x1080@30.00 ...
# wlr-randr should show: 1920x1080 px, 30.000000 Hz (current)
```

If the cmdline.txt edit is wrong (multi-line or malformed) the Pi
will still boot — `vc4-kms-v3d` falls back to the EDID-preferred mode,
which is exactly the 4K mode we're trying to escape.

## Lesson / follow-up

- **Tree-text recipes need regression tests.** They drift silently
  during refactors.
- Consider whether `setup-kiosk.sh` should append `video=HDMI-A-1:1920x1080@30`
  to `cmdline.txt` automatically. Pro: a 4K-display venue gets the
  right mode out of the box. Con: it's opinionated about source
  resolution and would surprise a future deployment that runs a
  4K source. Decision deferred — operator-applied for now, since
  source-resolution is a per-venue choice.
