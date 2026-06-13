#!/bin/bash
#
# install-staged-splash — Pi-side root-privileged installer.
#
# Invoked via sudo (no arguments) from accept-splash. The sudoers grant
# is for THIS exact command with NO arguments — that's why this script
# takes no parameters at all. The source file is at a fixed path; the
# destination is hardcoded.
#
# Side effects:
#   1. Copies the staged PNG into /home/kiosk/splash.png with the
#      correct ownership and mode.
#   2. Restarts kiosk.service so player.sh re-enters the splash loop
#      and mpv loads the new file (mpv with --loop on an image does
#      not re-read the file on its own).

set -euo pipefail

STAGED=/var/lib/splash-updater/staged.png
DEST=/home/kiosk/splash.png

if [[ ! -f "$STAGED" ]]; then
    echo "ERROR: no staged splash at $STAGED" >&2
    exit 2
fi

install -o kiosk -g kiosk -m 0644 "$STAGED" "$DEST"
rm -f "$STAGED"

# Restart the kiosk so the new splash appears immediately. The cage
# session blanks for ~1-2s during restart; that's acceptable for a
# splash-change event.
systemctl --machine=kiosk@.host --user restart kiosk.service
