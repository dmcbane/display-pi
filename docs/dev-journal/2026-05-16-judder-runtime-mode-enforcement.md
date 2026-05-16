# Judder root cause: cmdline `video=` honored by kernel, ignored at presentation

**Date:** 2026-05-16
**Status:** Active
**Affects:** `install/player.sh`, `install/kiosk.service`, `install/setup-kiosk.sh`,
`dev/set-hdmi-mode.sh`, `diagnostics/render-status.sh`, `diagnostics/judder.sh`

## Symptom

Lobby kiosk showed visible judder on the live stream. `judder.sh probe` reported
the active HDMI mode as `3840x2160@30.00` (kmsprint) and "preferred, current"
in `wlr-randr`, despite the project's single-source-of-truth HDMI forcing
mechanism (commit `24505b4`, dev-journal `2026-05-09-hdmi-mode-single-source-of-truth.md`)
that injects `video=HDMI-A-1:1920x1080@30` into `/boot/firmware/cmdline.txt`.

The kernel cmdline edit had been applied successfully (regression tests for the
mechanism continued to pass). The token was present at boot. The active mode
was still wrong.

## Root cause

The `video=` kernel parameter is a best-effort hint to DRM/KMS. When the
attached panel's EDID strongly advertises a preferred mode, vc4-kms-v3d on
Bookworm sometimes falls back to the EDID preferred mode even when the
cmdline `video=` token specifies an alternative — there is no error, the
kernel just picks EDID-preferred. The ONN 100012587 4K TV in use here
advertises 3840x2160@30 as preferred; the available modelist *does* include
1920x1080@30/60, but DRM didn't switch to it.

There was also no second layer to compensate: `install/player.sh` and
`install/kiosk.service` start `cage` and inherit whatever DRM negotiated at
boot. `wlr-randr` was installed only for diagnostics, never invoked to
enforce.

## Fix

Two-layer enforcement, one source of truth.

- **Source of truth** — `/etc/default/kiosk` with `KIOSK_MODE=<WxH@R>` and
  `KIOSK_OUTPUT=HDMI-A-1`, written by `install/setup-kiosk.sh` (new
  `configure_runtime_mode()` function) and `dev/set-hdmi-mode.sh` (extended
  remote script). Same `# === kiosk-setup BEGIN/END ===` marker pattern as
  config.txt edits so re-runs replace cleanly.
- **Boot-time layer (unchanged)** — kernel cmdline `video=HDMI-A-1:<mode>`.
  Still a useful hint; cooperative panels honor it.
- **Runtime layer (new, authoritative)** — `install/kiosk.service` loads
  `/etc/default/kiosk` via `EnvironmentFile=-`. `install/player.sh` reads
  `KIOSK_MODE`/`KIOSK_OUTPUT` and runs
  `wlr-randr --output "$KIOSK_OUTPUT" --mode "$KIOSK_MODE"` from
  `force_display_mode()` before mpv launches. Failures are logged to
  `/tmp/kiosk-wlr-randr.log` and tolerated — better to display the wrong
  size than not display at all.
- **Verification layer** — `diagnostics/render-status.sh` adds
  `check_display_mode()`, parsing `wlr-randr`'s "(current)" line and
  comparing against `KIOSK_MODE`. A mismatch emits WARN on the on-screen
  status overlay, surfacing the failure to the operator without needing
  a probe run.

`make hdmi-mode HDMI_MODE=…` and `make setup HDMI_MODE=…` continue to be the
operator-facing entry points; they now update both `cmdline.txt` and
`/etc/default/kiosk` in one shot.

## Lesson

A "single source of truth" only works if every layer that needs the value
actually consults it. The cmdline edit was the single source for the
kernel; nothing in user space was reading it back. Adding wlr-randr as a
runtime enforcement step closes the gap and gives us a check that fails
loudly (status WARN row) instead of silently (4K30 stream that "kind of
works but judders").

When relying on best-effort kernel hints under KMS, plan for a user-space
fallback. EDID is sovereign on cheap consumer panels.

## Follow-up notes

- If a future panel ignores `wlr-output-management` too, escalate to a
  custom EDID blob via `drm.edid_firmware=HDMI-A-1:edid/1080p.bin` on
  cmdline + `/lib/firmware/edid/1080p.bin`. Documented in `judder.sh tree`
  as a last-resort fallback. Not implemented yet; document any first use
  here.
- The Blackmagic ATEM Mini Pro can output 1080p25/30/50/60. If judder
  persists after this fix at `KIOSK_MODE=1920x1080@30`, check the ATEM's
  Video Standard — a 50/60 fps source against a 30Hz display will judder
  no matter what KMS does. Bump `KIOSK_MODE` to `1920x1080@60` (single
  command, no code change) to fix.
