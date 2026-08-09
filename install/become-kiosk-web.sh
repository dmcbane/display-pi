#!/bin/bash
#
# become-kiosk-web — drop into a shell as the user that OWNS the splash store,
# already sitting in it.
#
# The splash store (/var/lib/kiosk-splash) is owned by kiosk-web, a --system
# account created with /usr/sbin/nologin. That makes the obvious moves fail in
# unhelpful ways:
#
#   sudo -u kiosk-web -i        -> "This account is currently not available."
#   cd /var/lib/kiosk-splash    -> works, but every write needs another sudo
#
# so anyone asked to "go tidy up the splash folder" hits a wall that has
# nothing to do with what they were trying to do. This helper spells the
# incantation once: an explicit shell (bypassing the nologin login shell), a
# HOME the account can actually write to, and the store as the working dir.
#
# Usage:
#   become-kiosk-web                    # interactive shell in the splash store
#   become-kiosk-web ls -l              # one-shot command
#
# Installed to /usr/local/bin/become-kiosk-web by install/setup-kiosk.sh.
# Companion to become-kiosk (the kiosk *player* user, which needs a very
# different environment — see install/become-kiosk.sh for the D-Bus dance).

set -u

WEB_USER="${WEB_USER:-kiosk-web}"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Ask the single source of truth where the store is, so this helper can never
# disagree with the player about which folder matters. Fall back to the
# compiled-in default if the helper isn't alongside us (e.g. copied by hand).
if [[ -x "$SCRIPT_DIR/splash-store.sh" ]]; then
    SPLASH_DIR="$("$SCRIPT_DIR/splash-store.sh" path)"
else
    SPLASH_DIR="${SPLASH_DIR:-/var/lib/kiosk-splash}"
fi

if ! id "$WEB_USER" >/dev/null 2>&1; then
    echo "ERROR: user '$WEB_USER' does not exist on this system." >&2
    echo "       The volunteer web manager has not been set up here." >&2
    echo "       Run: make setup-web HOST=<this-pi>" >&2
    exit 1
fi

if [[ ! -d "$SPLASH_DIR" ]]; then
    echo "ERROR: splash store '$SPLASH_DIR' does not exist." >&2
    echo "       Run 'make deploy' (or install/setup-kiosk.sh) to create it." >&2
    exit 1
fi

# kiosk-web's passwd home is /nonexistent (--no-create-home). Point HOME at the
# account's own state dir instead, so bash can write .bash_history there rather
# than failing, or worse, littering the splash store — the web manager lists
# every file in that folder.
WEB_HOME=/var/lib/kiosk-web
[[ -d "$WEB_HOME" ]] || WEB_HOME="$SPLASH_DIR"

# Two sudo details, both learned the hard way:
#
#   * `-i` is out — it runs the account's login shell, which is nologin. Name
#     the shell explicitly instead.
#   * The variables go through `env`, not through sudo's own `VAR=value`
#     syntax. The deploy sudoers grants `NOPASSWD: ALL` but no SETENV tag, so
#     `sudo -u kiosk-web HOME=... bash` is refused outright ("you are not
#     allowed to set the following environment variables"). Running `env` as
#     the command sidesteps sudo's env policy entirely — same as become-kiosk
#     would need if it didn't carry an explicit SETENV grant.
if [[ $# -eq 0 ]]; then
    echo "You are now $WEB_USER, in $SPLASH_DIR. Type 'exit' when done."
    exec sudo -u "$WEB_USER" env HOME="$WEB_HOME" SPLASH_DIR="$SPLASH_DIR" \
        /bin/bash -c 'cd "$SPLASH_DIR" && exec /bin/bash'
else
    exec sudo -u "$WEB_USER" env HOME="$WEB_HOME" SPLASH_DIR="$SPLASH_DIR" \
        /bin/bash -c 'cd "$SPLASH_DIR" && exec "$@"' -- "$@"
fi
