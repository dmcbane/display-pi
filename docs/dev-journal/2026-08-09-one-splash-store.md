# Two splash folders, one of them unread

**Date:** 2026-08-09
**Status:** Fixed in v0.29.0
**Affects:** `install/player.sh`, `install/setup-kiosk.sh`, `dev/deploy.sh`,
`install/kiosk-web-setup.sh`, `install/install-staged-splash.sh`

## Symptom

Looking at `/home/kiosk/splash.d/` on a provisioned Pi, `02-c242.png` did not
appear to hold the c242 slide. The repo's copies are unambiguous and unchanged
since the commit that added them:

| file | md5 | size |
|---|---|---|
| `images/splash.d/01-rcc.png` | `8e0c1bb8…` | 987 KB |
| `images/splash.d/02-c242.png` | `4882068a…` | 3.0 MB |

so whatever the Pi was showing, it was not a repo problem. Chasing the
filename led straight into the real defect, which is not about that file at
all.

## Root cause

Provisioning created **two** image folders and only told the player about one
of them:

| step | what it did | who read it |
|---|---|---|
| 1 `setup` | wrote `/home/kiosk/splash.png` | player, until step 3 |
| 2 `deploy` | symlinked `/home/kiosk/splash.d` → the deployed repo working tree | player, until step 3 |
| 3 `setup-web` | created `/var/lib/kiosk-splash`, seeded it **once**, and wrote `SPLASH_DIR` into `/etc/default/kiosk` | player, from then on |

After step 3 the player read only `/var/lib/kiosk-splash`. The other two paths
kept existing and kept accepting writes — every `make deploy` faithfully
re-pointed a symlink nothing consulted. Because the store is seeded
only-if-empty, the repo's images and the images on screen could differ
indefinitely, and nothing on the Pi said which folder was live.

The player's `SPLASH_IMAGE` fallback made it worse: an empty or missing
rotation folder didn't produce an error, it produced a stale single image. The
failure mode was invisible by construction.

## Fix

One location, and one implementation of "where is it":

- `install/splash-store.sh` — the single helper that answers `path`, and does
  `ensure` / `seed` / `migrate`. All three provisioning steps call it, so they
  cannot drift apart again.
- `SPLASH_DIR` is written to `/etc/default/kiosk` at **step 1**, not step 3, so
  every later step aims at the folder the finished Pi actually reads.
- `deploy` no longer symlinks anything into `/home/kiosk`. It runs
  `splash-store.sh migrate`, which absorbs a legacy folder's images (unlinking
  a legacy *symlink* rather than recursing through it — deleting through that
  link would have eaten the repo's own `images/splash.d`) and removes both
  legacy paths.
- `player.sh` lost `SPLASH_IMAGE`. An empty store is now an error in the log,
  not a stale slide.

Seeding stays **only-if-empty** everywhere. The consequence is worth stating
plainly: on a provisioned Pi, editing `images/splash.d/` and deploying does
*nothing*. The repo folder is a fresh-install seed. Live slides are changed
through the web manager or `become-kiosk-web`.

## Operator ergonomics that fell out of this

The store is owned by `kiosk-web`, a `--system` account with
`/usr/sbin/nologin`, so `sudo -u kiosk-web -i` fails with "This account is
currently not available" — a wall with nothing to do with the actual task.
Two helpers now cover it:

- `become-kiosk-web` — a real shell as the store's owner, already in the
  folder. Uses `env` rather than sudo's `VAR=value` syntax, because the deploy
  sudoers grants `NOPASSWD: ALL` without a `SETENV` tag.
- `kiosk-config` — edits `/etc/default/kiosk` via a copy, and refuses to
  install anything `bash -n` rejects, that fails when sourced, or that isn't a
  plain `KEY=value` line. `EnvironmentFile=` ignores what it cannot parse
  *silently*, so a bad edit there surfaces as a black screen at the next boot.
  It opens `micro` by default (modeless, self-documenting) and declines `nano`
  even when `$EDITOR` asks for it.

Both are installed to `/usr/local/bin` by `setup-kiosk.sh`, alongside
`splash-store` itself — `splash-store path` answers "which folder is live?"
directly on the Pi, and `make splash-ls` asks it from the workstation.
