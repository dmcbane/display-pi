#!/bin/bash
#
# sshd-password-toggle — Admin script. Run on the Pi to allow login by
# public key OR password, and to easily flip password auth on/off later.
#
# Both methods are managed through a single drop-in:
#   /etc/ssh/sshd_config.d/00-display-pi-auth.conf
#
# Why the `00-` prefix: files in /etc/ssh/sshd_config.d/ are read in
# lexical order, and sshd uses the FIRST value it sees for each keyword.
# Raspberry Pi OS Includes that directory at the very top of the stock
# /etc/ssh/sshd_config, so a drop-in that sorts first overrides BOTH later
# drop-ins (e.g. the key-only file rpi-imager writes when you pick
# "allow public-key authentication only") AND the stock config.
#
# PubkeyAuthentication is ALWAYS forced on, so `off` (key-only) can never
# lock out key-based logins. The new config is validated with `sshd -t`
# before it is applied, and applied with `systemctl reload` (NOT restart)
# so in-flight SSH sessions — including the one you ran this from — survive
# even if something is wrong.
#
# Usage (on the Pi):
#   sudo bash install/sshd-password-toggle.sh on      # allow key OR password
#   sudo bash install/sshd-password-toggle.sh off     # key-only
#   sudo bash install/sshd-password-toggle.sh status  # show effective auth (default)
#
# From the workstation:
#   make ssh-password STATE=on|off|status
#
# Re-running is safe — each step is idempotent.

set -euo pipefail

DROPIN=/etc/ssh/sshd_config.d/00-display-pi-auth.conf

log() { printf '\033[1;34m[sshd-password-toggle]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sshd-password-toggle] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Raspberry Pi OS names the unit `ssh`; some distros use `sshd`. Reload
# (not restart) so established SSH sessions are not dropped.
reload_sshd() {
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
}

# Print the fully resolved, effective auth settings — the real source of
# truth, not just what our drop-in says. `sshd -T` needs to read host keys,
# so it must run as root.
show_status() {
    log "Effective SSH authentication settings:"
    sshd -T 2>/dev/null \
        | grep -E '^(pubkeyauthentication|passwordauthentication) ' \
        || die "Could not read effective sshd config (sshd -T failed; try with sudo)."
}

# Write the drop-in with the requested password setting, validate the whole
# resolved config, then reload. Pubkey auth is pinned on regardless.
write_dropin() {
    local password="$1"   # "yes" or "no"

    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# Managed by display-pi — install/sshd-password-toggle.sh. Do not edit by hand.
# Sorts first in sshd_config.d/ so it overrides later drop-ins and the stock
# config (sshd uses the first value it sees for each keyword). Pubkey auth is
# always enabled here so disabling passwords can't lock out key-based logins.
PubkeyAuthentication yes
PasswordAuthentication ${password}
# Root is never reachable over SSH regardless of the password setting above.
# This drop-in sorts first, so it wins over the stock config / base image.
PermitRootLogin no
EOF

    install -d -m 0755 "$(dirname "$DROPIN")"
    install -o root -g root -m 0644 "$tmp" "$DROPIN"
    rm -f "$tmp"

    # Validate the merged config before reloading. On failure, leave sshd
    # running on its current (still-loaded) config and tell the operator.
    if ! sshd -t; then
        die "sshd -t rejected the new config. Wrote $DROPIN but did NOT reload sshd."
    fi
    reload_sshd
}

main() {
    local cmd="${1:-status}"

    case "$cmd" in
        status)
            show_status
            exit 0
            ;;
        on|off)
            [[ $EUID -eq 0 ]] || die "Must run as root to change SSH config: sudo bash $0 $cmd"
            ;;
        *)
            die "Usage: $(basename "$0") on|off|status  (got: '$cmd')"
            ;;
    esac

    if [[ "$cmd" == "on" ]]; then
        log "Enabling password authentication (login by public key OR password)..."
        write_dropin yes
    else
        log "Disabling password authentication (public key only)..."
        write_dropin no
    fi

    log "Applied. Wrote $DROPIN and reloaded sshd."
    show_status
}

main "$@"
