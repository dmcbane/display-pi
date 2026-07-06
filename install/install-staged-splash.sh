#!/bin/bash
#
# install-staged-splash — Pi-side root-privileged installer.
#
# Invoked via sudo (no arguments) from accept-splash. The sudoers grant
# is for THIS exact command with NO arguments — that's why this script
# takes no parameters at all. The source is whatever single staged.* file
# accept-splash left in the fixed staging dir; the staged extension
# (png/jpg/jpeg/gif/webp — accept-splash validated the content) carries
# the format, and the destination name follows it.
#
# Side effects:
#   1. Copies the staged image into the kiosk's splash rotation folder as
#      the volunteer slide (a fixed stem, so repeat uploads overwrite —
#      latest wins, no stale buildup), with correct ownership and mode.
#      Volunteer slides in other formats are removed first so exactly one
#      volunteer slide is ever in the rotation.
#   2. Restarts kiosk.service so player.sh re-enters the splash loop
#      and mpv loads the new file (mpv with --loop on an image does
#      not re-read the file on its own).

set -euo pipefail

STAGING_DIR=/var/lib/splash-updater
# The kiosk rotates through /home/kiosk/splash.d; the volunteer slide lives
# there under a fixed, order-leading stem. Repeat uploads overwrite it.
SPLASH_DIR=/home/kiosk/splash.d

shopt -s nullglob
staged=("$STAGING_DIR"/staged.*)
shopt -u nullglob
if (( ${#staged[@]} == 0 )); then
    echo "ERROR: no staged splash in $STAGING_DIR" >&2
    exit 2
fi
if (( ${#staged[@]} > 1 )); then
    echo "ERROR: multiple staged splash files (${staged[*]}) — re-upload" >&2
    exit 2
fi
STAGED="${staged[0]}"

ext="${STAGED##*.}"
case "$ext" in
    png|jpg|jpeg|gif|webp) ;;
    *)
        echo "ERROR: staged splash has unsupported extension: .$ext" >&2
        exit 2 ;;
esac
DEST="$SPLASH_DIR/00-volunteer.$ext"

install -d -o kiosk -g kiosk -m 0755 "$SPLASH_DIR"
rm -f "$SPLASH_DIR"/00-volunteer.*
install -o kiosk -g kiosk -m 0644 "$STAGED" "$DEST"
rm -f "$STAGED"

# Restart the kiosk so the new splash appears immediately. The cage
# session blanks for ~1-2s during restart; that's acceptable for a
# splash-change event.
systemctl --machine=kiosk@.host --user restart kiosk.service
