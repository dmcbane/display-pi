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
# The volunteer slide must land in the rotation folder the player actually
# reads. kiosk.service loads SPLASH_DIR from /etc/default/kiosk (the single
# source of stream/splash config; kiosk-web-setup.sh points it at the
# web-managed folder) — honor the same setting, falling back to the legacy
# folder when it's unset.
SPLASH_DIR=/home/kiosk/splash.d
KIOSK_ENV_FILE=/etc/default/kiosk
if [[ -r "$KIOSK_ENV_FILE" ]]; then
    configured=$(grep -E '^SPLASH_DIR=' "$KIOSK_ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')
    [[ -n "$configured" ]] && SPLASH_DIR="$configured"
fi

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

# The legacy folder is kiosk-owned but the web-managed one belongs to
# kiosk-web — give the slide the folder's owner so whichever manager owns
# the folder can also delete/reorder the slide.
if [[ ! -d "$SPLASH_DIR" ]]; then
    install -d -o kiosk -g kiosk -m 0755 "$SPLASH_DIR"
fi
owner=$(stat -c '%U' "$SPLASH_DIR")
group=$(stat -c '%G' "$SPLASH_DIR")
rm -f "$SPLASH_DIR"/00-volunteer.*
install -o "$owner" -g "$group" -m 0644 "$STAGED" "$DEST"
rm -f "$STAGED"

# Restart the kiosk so the new splash appears immediately. The cage
# session blanks for ~1-2s during restart; that's acceptable for a
# splash-change event.
systemctl --machine=kiosk@.host --user restart kiosk.service
