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

# If the caller already has XDG_RUNTIME_DIR pointing at the kiosk user's
# runtime dir, use that. Otherwise fall back to /run/user/<kiosk-uid>.
# Inline form matches the TODO ("if $XDG_RUNTIME_DIR is not defined,
# default to /run/user/$(id -u)") so the pattern is grep-able from
# either side. We pass KIOSK_USER to id so the helper still picks the
# right directory when invoked by root or an unrelated SSH user.
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u "$KIOSK_USER")}"

# If the user's runtime dir doesn't yet exist (no prior systemd --user
# session), surface a hint but proceed — sudo will print its own error
# from systemctl if the bus really isn't reachable.
if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
    echo "WARN: $XDG_RUNTIME_DIR does not exist — has '$KIOSK_USER' logged in" >&2
    echo "      since boot? (loginctl enable-linger should have created it.)" >&2
fi

# -i runs a login shell when no command is given; with extra args sudo
# treats them as the command to run. SETENV is granted via the deploy
# sudoers (install/kiosk-deploy.sudoers) so XDG_RUNTIME_DIR survives.
if [[ $# -eq 0 ]]; then
    exec sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" -i
else
    exec sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" -i -- "$@"
fi
