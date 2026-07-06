---
title: "Admin: SSH-Bundle Splash Workflow — display-pi"
description: Operator runbook for the older SSH-key splash-update bundle — the offline fallback to the browser-based web manager.
---

# Admin: Splash-Update Workflow

> **This is the offline / SSH fallback.** The primary way volunteers manage
> splash images is now the browser-based [web manager](web-manager-https.html).
> Use this SSH-bundle workflow when a browser or HTTPS isn't available.

This is the operator-side runbook for the volunteer splash-update
feature added in v0.9.0. Volunteers upload a splash slide to the kiosk
Pi over SSH using a hand-delivered bundle. This doc covers what you (the
AV admin) do.

> **Rotation (v0.11.0+):** the kiosk now cycles through the images in
> `/home/kiosk/splash.d/`, advancing one image each time the splash is
> re-entered (no timer). The volunteer upload lands in that folder as
> `00-volunteer.<ext>` (extension follows the uploaded format) and
> **joins the rotation** — repeat uploads overwrite it (latest wins).
> Admin slides are managed from the repo's `images/splash.d/` via
> `make deploy`; that sync excludes `*-volunteer.*` so it never wipes
> the volunteer's slide.

For the volunteer-facing instructions, see
[`docs/volunteer-splash-update.md`](volunteer-splash-update.md) — that
file also ships inside every bundle as `README.md`.

---

## One-time Pi setup

Run this once, ever, on the kiosk Pi:

```bash
ssh displaypi 'sudo bash /home/kiosk/display-pi/install/splash-updater-setup.sh'
```

What it does:

- Creates the `splash-updater` system user with a locked password and
  `/bin/bash` as login shell (sshd's `ForceCommand` needs a real shell;
  the `restrict` flag in `authorized_keys` + locked password keep the
  account from ever being usable for anything else).
- Installs `/usr/local/libexec/accept-splash` and
  `/usr/local/libexec/install-staged-splash` from the deployed repo.
- Writes `/etc/sudoers.d/splash-updater` with a no-args `NOPASSWD:`
  grant for the install-helper only.
- Generates `/etc/ssh/splash-updater_ed25519` if missing.
- Writes the restricted `~splash-updater/.ssh/authorized_keys` with the
  `ForceCommand` + `restrict` + every `no-*` hardening option.

Re-running is safe: each step is idempotent. Use that if you ever need
to repair a broken state.

---

## Building a bundle for a volunteer

```bash
make volunteer-bundle
```

Produces `volunteer-bundle.zip` (~13 KB) in the repo root:

| File in zip | Purpose |
|---|---|
| `splash-replace.sh` | Mac/Linux client script |
| `splash-replace.ps1` | Windows client script |
| `README.md` | The volunteer-facing usage doc |
| `splash-updater` | Live private key, pulled from the Pi |

### Delivering the bundle

- **USB stick**: preferred. Hand it to the volunteer in person.
- **Secure file-share** (e.g. a password-protected upload, Signal,
  Keybase): acceptable if you can't meet in person.
- **Plain email**: don't. Email isn't encrypted by default, and the
  private key inside the zip is what authorizes splash replacements.

The zip is gitignored (see `.gitignore`) so accidentally running
`git add -A` won't publish the key. The bundle file itself, once
created, lives only on your workstation until you hand it off — delete
your local copy after delivery if you want belt-and-suspenders.

---

## Rotating / revoking access

The same private key is shared across all volunteers (this is fine —
the `ForceCommand` is what enforces "this key can only replace the
splash"). To revoke access for everyone:

```bash
# Re-running setup regenerates the key. The old key stops working
# immediately because authorized_keys gets rewritten with the new
# public key.
ssh displaypi 'sudo rm /etc/ssh/splash-updater_ed25519 /etc/ssh/splash-updater_ed25519.pub'
ssh displaypi 'sudo bash /home/kiosk/display-pi/install/splash-updater-setup.sh'

# Re-bundle and re-distribute to all volunteers you trust.
make volunteer-bundle
```

If you ever need to disable splash updates entirely without removing
the user (e.g. during a security incident), comment out or delete
`~splash-updater/.ssh/authorized_keys` on the Pi.

---

## What the Pi enforces (security recap)

Even if a volunteer's bundle leaks, the worst anyone with the key can
do is overwrite the one volunteer slide with a valid 1920×1080 image.
The full chain:

1. **SSH layer.** Only key-based auth (password is locked); only the
   one key in `authorized_keys` is accepted.
2. **`authorized_keys` flags.** `restrict` is default-deny for sshd;
   the `no-*` options forbid pty, X11, agent, port forwarding.
3. **`ForceCommand`.** Whatever the client tries to run is ignored;
   `/usr/local/libexec/accept-splash` runs instead, getting the
   client's stdin as input.
4. **Validator.** `accept-splash` checks the format (must be PNG, JPEG,
   GIF, or WebP), dimensions (must be 1920×1080), file size (≤ 10 MB),
   and the format's end-of-stream marker (PNG `IEND`, JPEG EOI, GIF
   trailer, WebP RIFF size — catches truncated uploads).
5. **Sudo grant.** `splash-updater` can run exactly *one* command via
   sudo — `/usr/local/libexec/install-staged-splash`, with zero
   arguments allowed. No wildcards, no parameter injection.
6. **Installer.** That helper reads the single `staged.<ext>` file from
   the fixed staging dir (`/var/lib/splash-updater/`) — the extension,
   whitelisted to the four formats, is how the argument-less sudo call
   learns the format — and writes to the fixed
   `/home/kiosk/splash.d/00-volunteer.<ext>` (no path choice), removing
   volunteer slides in other formats so exactly one is in rotation,
   then restarts the kiosk so the new slide appears within ~2 seconds.

End-to-end verified on the live Pi during initial deployment: full
PNGs accepted, truncated PNGs rejected, shell attempts rejected, scp
to arbitrary paths blocked, port forwards refused.

---

## Troubleshooting (admin view)

| Volunteer reports | Most likely cause | Where to look on the Pi |
|---|---|---|
| `Permission denied (publickey)` | Volunteer has the wrong key, or `authorized_keys` was rewritten | `sudo cat ~splash-updater/.ssh/authorized_keys` |
| `Connection refused` | sshd not running, or Pi off network | `systemctl status ssh`, `ping displaypi` |
| `ERROR: … file appears truncated` | Genuine corrupt input, or upload interrupted | Ask volunteer to re-export the image |
| `ERROR: image must be 1920x1080` | Volunteer's resize step missed | Their problem; the validator caught it |
| Splash didn't change visibly | Stream was live (splash only shows when idle), or the restart raced/hung | `become-kiosk systemctl --user status kiosk.service` |
| Disk filling | Stuck staged file (rare) | `ls -lh /var/lib/splash-updater/` |

Live debugging: `sudo journalctl _SYSTEMD_USER_UNIT=kiosk.service -n 50`
shows the kiosk's recent activity including the service restart after
a successful splash replace.

---

## File reference

| Repo path | Where it lives on the Pi | Owner |
|---|---|---|
| `install/accept-splash.sh` | `/usr/local/libexec/accept-splash` | `root:root` 0755 |
| `install/install-staged-splash.sh` | `/usr/local/libexec/install-staged-splash` | `root:root` 0755 |
| `install/splash-updater-setup.sh` | (admin runs from deployed repo) | — |
| `dev/splash-replace.sh` | (volunteer's machine) | — |
| `dev/splash-replace.ps1` | (volunteer's machine) | — |
| `docs/volunteer-splash-update.md` | (ships inside bundle) | — |
