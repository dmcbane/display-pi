#!/bin/bash
#
# set-hdmi-mode.sh — Apply (or clear) an HDMI mode on an already-deployed Pi.
#
# Under Bookworm KMS the only working HDMI mode-forcing knob is the kernel
# `video=` parameter in /boot/firmware/cmdline.txt. This script:
#   1. Backs up cmdline.txt with a timestamped suffix.
#   2. Strips any existing `video=HDMI-A-1:*` token (so re-runs replace
#      cleanly — idempotent).
#   3. Appends `video=HDMI-A-1:<MODE>` (unless MODE=="none").
#   4. Sanity-checks the result is exactly one non-empty line. If not,
#      restores the backup and exits non-zero (cmdline.txt format errors
#      brick boot).
#   5. Optionally reboots the Pi (mode change requires reboot to take effect).
#
# A "corrected" config.txt is also offered: under KMS, `hdmi_group=`,
# `hdmi_mode=`, `hdmi_drive=`, `hdmi_enable_4kp60=` lines are inert.
# This script only warns about them; it does not edit config.txt
# automatically (those lines may be intentional for a non-kiosk setup).
#
# Usage:
#   dev/set-hdmi-mode.sh <HOST> <MODE>
#   dev/set-hdmi-mode.sh <HOST> none           # remove forcing
#
# Examples:
#   dev/set-hdmi-mode.sh displaypi 1920x1080@30
#   dev/set-hdmi-mode.sh displaypi 1920x1080@60
#   dev/set-hdmi-mode.sh displaypi none
#
# After it returns, you'll be prompted to reboot. The new mode applies
# at the next boot. Verify on the Pi with:
#   make judder-probe HOST=<HOST>
#   # kmsprint should report the requested resolution under Crtc.

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <HOST> <MODE|none>" >&2
    echo "  e.g.: $0 displaypi 1920x1080@30" >&2
    echo "        $0 displaypi none" >&2
    exit 2
fi

HOST="$1"
MODE="$2"

# Light validation: MODE must be "none" or look like WIDTHxHEIGHT@RATE
if [[ "$MODE" != "none" ]] && ! [[ "$MODE" =~ ^[0-9]+x[0-9]+@[0-9]+(D)?$ ]]; then
    echo "ERROR: MODE must be 'none' or 'WxH@R' (e.g. 1920x1080@30); got: $MODE" >&2
    exit 2
fi

log() { printf '\033[1;34m[set-hdmi-mode]\033[0m %s\n' "$*"; }

# The remote half: edits cmdline.txt safely. Receives MODE as $1.
REMOTE_SCRIPT='
set -euo pipefail
MODE="$1"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || { echo "ERROR: $CMDLINE not found" >&2; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${CMDLINE}.bak-${STAMP}"
sudo cp -a "$CMDLINE" "$BACKUP"

# Read current line, normalize whitespace, strip any existing video=HDMI-A-1:*
current=$(sudo cat "$CMDLINE" | tr -s "[:space:]" " " | sed "s/^ //;s/ \$//")
stripped=$(printf "%s" "$current" | sed -E "s/( |^)video=HDMI-A-1:[^ ]+//g; s/  +/ /g; s/^ //; s/ \$//")

if [ "$MODE" = "none" ]; then
    new="$stripped"
    echo "Removing video=HDMI-A-1: from cmdline.txt"
else
    new="${stripped} video=HDMI-A-1:${MODE}"
    echo "Setting video=HDMI-A-1:${MODE}"
fi

# Refuse empty
if [ -z "$new" ]; then
    echo "ERROR: refusing to write empty cmdline.txt; restoring backup" >&2
    sudo cp -a "$BACKUP" "$CMDLINE"
    exit 1
fi

# Write
echo "$new" | sudo tee "$CMDLINE" > /dev/null

# Sanity-check: must be exactly one non-empty line
n=$(grep -c . "$CMDLINE")
if [ "$n" -ne 1 ]; then
    echo "ERROR: cmdline.txt has $n non-empty lines (must be 1); restoring backup" >&2
    sudo cp -a "$BACKUP" "$CMDLINE"
    exit 1
fi

echo "cmdline.txt updated:"
echo "  $new"
echo "Backup: $BACKUP"

# Runtime mode-enforcement layer: /etc/default/kiosk is read by
# kiosk.service (EnvironmentFile=-) and consumed by player.sh
# (force_display_mode runs wlr-randr inside the cage session). Keeping
# this in sync with cmdline.txt is the whole point of this script.
ENV_FILE=/etc/default/kiosk
MARKER_START="# === kiosk-setup BEGIN ==="
MARKER_END="# === kiosk-setup END ==="

if [ "$MODE" = "none" ]; then
    KIOSK_MODE_VALUE=""
else
    KIOSK_MODE_VALUE="$MODE"
fi

if [ -f "$ENV_FILE" ]; then
    sudo cp -a "$ENV_FILE" "${ENV_FILE}.bak-${STAMP}"
    sudo sed -i "/${MARKER_START}/,/${MARKER_END}/d" "$ENV_FILE"
fi
sudo tee -a "$ENV_FILE" > /dev/null <<ENVEOF
${MARKER_START}
# Runtime HDMI mode (set by dev/set-hdmi-mode.sh on ${STAMP}).
KIOSK_MODE=${KIOSK_MODE_VALUE}
KIOSK_OUTPUT=HDMI-A-1
${MARKER_END}
ENVEOF
sudo chmod 644 "$ENV_FILE"
echo "$ENV_FILE updated (KIOSK_MODE=${KIOSK_MODE_VALUE})"

# Inert-key warning on config.txt (do not auto-edit; the operator may have
# intentional non-kiosk config in there).
CONFIG=/boot/firmware/config.txt
if [ -f "$CONFIG" ] && sudo grep -qE "^[[:space:]]*(hdmi_group|hdmi_mode|hdmi_drive|hdmi_enable_4kp60)" "$CONFIG"; then
    echo "WARNING: $CONFIG still contains legacy hdmi_* keys (KMS ignores them)."
    echo "         Consider removing them to avoid confusion. Lines:"
    sudo grep -nE "^[[:space:]]*(hdmi_group|hdmi_mode|hdmi_drive|hdmi_enable_4kp60)" "$CONFIG" | sed "s/^/         /"
fi
'

log "Connecting to $HOST..."
# /boot/firmware/cmdline.txt writes aren't in kiosk-deploy.sudoers (and
# shouldn't be — they're rare, root-level, and only sane to gate on a
# password), so the remote `sudo cp/tee` must be able to prompt. Two pieces:
#   1. `ssh -t` allocates a remote PTY (sudo reads passwords from /dev/tty,
#      not stdin), so the local terminal can talk to the prompt.
#   2. Don't feed the script via stdin (`bash -s <<<…`); base64 it into the
#      command argument instead. Otherwise the local stdin is closed once
#      the here-string is sent and the user can't type the password.
script_b64=$(printf '%s' "$REMOTE_SCRIPT" | base64 -w0)
ssh -t "$HOST" "echo $script_b64 | base64 -d | bash -s -- '$MODE'"

echo
read -r -p "Reboot $HOST now to apply? [y/N] " ans
if [[ "$ans" =~ ^[Yy] ]]; then
    log "Rebooting $HOST..."
    ssh "$HOST" 'sudo reboot' || true
    log "Reboot command sent. Pi will come back in ~30s."
else
    log "Skipping reboot. The new mode will apply on the next reboot."
fi
