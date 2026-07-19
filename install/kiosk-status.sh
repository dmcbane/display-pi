#!/bin/bash
#
# kiosk-status — Print the same system-status checks shown on the web manager
# UI and the HDMI debug screen.
#
# Usage (once installed by deploy.sh to /usr/local/bin/kiosk-status):
#   kiosk-status
#
# Works from any SSH session as the deploy user — re-execs itself as the kiosk
# user via sudo (NOPASSWD, covered by install/kiosk-deploy.sudoers). Works as
# root or kiosk directly without sudo.
#
# Output: aligned text table to stdout, same format as `make diag`.
# Side-effect: refreshes /tmp/kiosk-status.png (the HDMI debug image).

set -u

KIOSK_USER="${KIOSK_USER:-kiosk}"
KIOSK_DIR="${KIOSK_DIR:-/home/kiosk/display-pi}"

if [[ "$(id -un)" != "$KIOSK_USER" ]] && [[ "$(id -u)" != "0" ]]; then
    KIOSK_UID="$(id -u "$KIOSK_USER" 2>/dev/null)" || {
        echo "ERROR: user '$KIOSK_USER' not found." >&2
        exit 1
    }
    exec sudo -u "$KIOSK_USER" \
        XDG_RUNTIME_DIR="/run/user/$KIOSK_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$KIOSK_UID/bus" \
        "$0" "$@"
fi

exec "${KIOSK_DIR}/diagnostics/render-status.sh" /tmp/kiosk-status.png
