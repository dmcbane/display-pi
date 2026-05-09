# HDMI mode: single source of truth (HDMI_MODE in setup-kiosk.sh + set-hdmi-mode.sh)

**Date:** 2026-05-09
**Status:** Active
**Affects:** `install/setup-kiosk.sh`, `dev/set-hdmi-mode.sh`, `Makefile`,
`diagnostics/judder.sh` (tree text)

## Context

Three layers of HDMI-mode information lived in this repo:

1. **`install/setup-kiosk.sh`** — wrote `cmdline.txt` (and `config.txt`)
   on first-time bootstrap, but did not expose any HDMI-mode knob.
2. **`diagnostics/judder.sh tree`** — documented the recipe in
   free-form prose under Diagnosis A Option 2.
3. **The deployed Pi's `/boot/firmware/cmdline.txt` and `config.txt`**
   — the actual state, which an operator might edit manually following
   the prose recipe in (2).

The recipe in (2) regressed silently in commit `6aa7d4e` (see
`docs/dev-journal/2026-05-09-hdmi-mode-regression.md`). When the
operator followed the (now-stale) prose recipe, they edited
`config.txt` with `hdmi_group=` / `hdmi_mode=`, which Bookworm KMS
silently ignores. Time wasted: a venue reboot that did nothing.

## Decision

Collapse the three layers into one. The HDMI mode lives in a single
env var, `HDMI_MODE`, consumed by `install/setup-kiosk.sh`'s
`configure_boot()`. The Makefile and a standalone fix-script invoke
the same code path.

### Components

- **`HDMI_MODE` env var** in `install/setup-kiosk.sh`. Format:
  `WxH@R` (e.g. `1920x1080@30`), `none` (explicit clear), or unset
  (no-op — leave whatever is there).
- **`configure_boot()` rewrites `cmdline.txt` idempotently.** Any
  prior `video=HDMI-A-1:*` token is stripped before the new one is
  added. Re-running with a different mode is a clean replace, not
  an append.
- **`dev/set-hdmi-mode.sh <HOST> <MODE>`** — for already-deployed
  Pis. Same idempotent strip-then-add, with a backup, a single-line
  sanity check (cmdline.txt format errors brick boot), and an
  optional reboot. Also warns about inert legacy `hdmi_*` keys
  still sitting in `config.txt` but does not auto-edit them.
- **`make hdmi-mode HDMI_MODE=…`** — Makefile wrapper around the
  fix-script.
- **`make setup HDMI_MODE=…`** — forwards `HDMI_MODE` to the
  bootstrap so a fresh Pi gets the right mode out of the box.
- **`judder.sh tree` Diagnosis A Option 2** — now points at
  `make hdmi-mode HDMI_MODE=…` as the canonical mechanism, with the
  manual `sudoedit` recipe demoted to a fallback. Tests in
  `tests/run-tests.sh` assert the tree references the make target
  and that `setup-kiosk.sh` actually contains the `video=HDMI-A-1:`
  token logic — so the recipe and the implementation can no longer
  drift independently.

### Why not auto-strip legacy `hdmi_*` from `config.txt`?

`config.txt` outside the `# === kiosk-setup BEGIN/END ===` block may
contain operator-intentional config (e.g. for non-kiosk Pis sharing
the codebase, or for future Pi 5 quirks). Auto-stripping risks
deleting something deliberate. Inside the managed block, the
`sudoedit` recipe never could be there in the first place because
`configure_boot()` already deletes-and-rewrites the block on every
re-run (line 293 of `setup-kiosk.sh`). The fix-script warns about
legacy keys it sees but doesn't touch them.

## Operator playbook

| Situation | Command |
|-----------|---------|
| Fresh Pi, want forced mode | `make setup HDMI_MODE=1920x1080@30` |
| Already-deployed Pi, set mode | `make hdmi-mode HDMI_MODE=1920x1080@30` |
| Clear forcing (let EDID pick) | `make hdmi-mode HDMI_MODE=none` |
| Verify after reboot | `make judder-probe` (look at `kmsprint` Crtc) |

## Lesson

When prose documentation describes the same operation as a code path
in the same repo, they will drift. Make the prose either point at
the code path (`make hdmi-mode …`) or generated from it. Free-form
prose is fine for the *why*; never for the *how*, when the *how*
already lives in code.
