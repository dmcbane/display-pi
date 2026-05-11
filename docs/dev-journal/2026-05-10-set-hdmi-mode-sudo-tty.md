# `make hdmi-mode` died with "sudo: a terminal is required to read the password"

**Date:** 2026-05-10
**Status:** Fixed in 0.2.2
**Affects:** `dev/set-hdmi-mode.sh`

## Symptom

```
$ make hdmi-mode HDMI_MODE=1920x1080@50
[set-hdmi-mode] Connecting to displaypi...
sudo: a terminal is required to read the password; either use the -S option
to read from standard input or configure an askpass helper
sudo: a password is required
make: *** [Makefile:190: hdmi-mode] Error 1
```

## Root cause

Two compounding mistakes in the original `dev/set-hdmi-mode.sh`:

```bash
ssh "$HOST" "bash -s -- '$MODE'" <<<"$REMOTE_SCRIPT"
```

1. **No remote PTY.** `sudo` reads passwords from `/dev/tty`, not stdin.
   Without `ssh -t`, the remote bash had no controlling terminal, so `sudo
   cp` / `sudo tee` (writing `/boot/firmware/cmdline.txt`) had nothing to
   prompt against.

2. **Script fed via stdin.** Even with `ssh -t`, the here-string `<<<"$REMOTE_SCRIPT"`
   would consume the local terminal's stdin to deliver the script.
   After the here-string EOF, ssh has no more local stdin to forward — so
   when the user goes to type their password, there's nowhere for it to
   reach the remote PTY.

These edits aren't in `install/kiosk-deploy.sudoers` and shouldn't be:
`/boot/firmware/cmdline.txt` is rarely-edited root state, the kind of thing
that's actively *better* behind a password gate. So a real prompt is the
correct behavior — the bug was that the wrapper made the prompt
unreachable.

## Fix

```bash
script_b64=$(printf '%s' "$REMOTE_SCRIPT" | base64 -w0)
ssh -t "$HOST" "echo $script_b64 | base64 -d | bash -s -- '$MODE'"
```

- `ssh -t` allocates the remote PTY.
- The script content rides in as a command-line argument (base64 to skip
  any quoting concerns), so local stdin stays attached to the user's
  terminal and forwards keystrokes to the remote PTY for `sudo` to read.

## Lesson

Whenever a wrapper script SSH-es somewhere and the remote work touches a
path outside the deploy NOPASSWD whitelist, design for the password prompt:
allocate a TTY, and don't borrow the local stdin for payload delivery.
