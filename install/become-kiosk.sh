#!/bin/bash
#
# become-kiosk — drop into an interactive shell as the kiosk user with
# XDG_RUNTIME_DIR set correctly. Required because most kiosk operations
# (systemctl --user kiosk.service, wpctl status, journalctl --user-unit=…)
# fail silently or with "Failed to connect to bus" if XDG_RUNTIME_DIR is
# missing or points at the invoking user's runtime dir.
#
# Usage:
#   become-kiosk                       # interactive login shell
#   become-kiosk systemctl --user …    # one-shot command
#
# Installed by install/setup-kiosk.sh to /usr/local/bin/become-kiosk so it
# is on $PATH for the deploy user from any SSH session. The kiosk user must
# already exist (setup-kiosk.sh creates it); this helper does not.

set -u

KIOSK_USER="${KIOSK_USER:-kiosk}"

if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    echo "ERROR: user '$KIOSK_USER' does not exist on this system." >&2
    echo "       Re-run install/setup-kiosk.sh, or set KIOSK_USER to the" >&2
    echo "       correct target user." >&2
    exit 1
fi

# XDG_RUNTIME_DIR must point at the KIOSK user's runtime dir, not the
# caller's. Don't trust an inherited value: pam_systemd has already set
# it to /run/user/<deploy_uid> for any SSH login, and falling back only
# on unset would silently route DBUS/wpctl/systemctl --user calls to the
# wrong user's bus. Overwrite unconditionally.
XDG_RUNTIME_DIR="/run/user/$(id -u "$KIOSK_USER")"

# If the user's runtime dir doesn't yet exist (no prior systemd --user
# session), surface a hint but proceed — sudo will print its own error
# from systemctl if the bus really isn't reachable.
if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
    echo "WARN: $XDG_RUNTIME_DIR does not exist — has '$KIOSK_USER' logged in" >&2
    echo "      since boot? (loginctl enable-linger should have created it.)" >&2
fi

# `sudo -u kiosk -i` sets up the login shell but does NOT establish a
# usable D-Bus user-bus address — empirically (2026-06-13), systemctl --user
# fails with "Failed to connect to user scope bus via local transport:
# Operation not permitted" unless we point DBUS_SESSION_BUS_ADDRESS at the
# user's bus socket explicitly. SETENV is granted via the deploy sudoers
# (install/kiosk-deploy.sudoers) so both vars survive.
DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

if [[ $# -eq 0 ]]; then
    exec sudo -u "$KIOSK_USER" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        -i
else
    exec sudo -u "$KIOSK_USER" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        -i -- "$@"
fi
