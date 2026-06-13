#!/bin/bash
#
# splash-updater-setup — Admin script. Run once on the Pi to enable
# volunteer splash-image uploads.
#
# Creates:
#   - splash-updater user (no shell, no password, no home shell access)
#   - /usr/local/libexec/accept-splash (validator, ForceCommand target)
#   - /usr/local/libexec/install-staged-splash (root installer)
#   - /var/lib/splash-updater/ (staging dir, owned by splash-updater)
#   - /etc/sudoers.d/splash-updater (NOPASSWD for the no-args installer)
#   - ~splash-updater/.ssh/authorized_keys (ForceCommand + restrict)
#   - /etc/ssh/splash-updater_ed25519 (keypair if not already present)
#
# At the end, prints the PRIVATE KEY and connection info you'll need to
# bundle with the volunteer client scripts (dev/splash-replace.{sh,ps1}).
#
# Usage:
#   sudo bash install/splash-updater-setup.sh
#
# Re-running is safe — each step is idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SU_USER=splash-updater
STAGING_DIR=/var/lib/splash-updater
LIBEXEC=/usr/local/libexec
ACCEPT_DST="$LIBEXEC/accept-splash"
INSTALL_DST="$LIBEXEC/install-staged-splash"
SUDOERS_DST=/etc/sudoers.d/splash-updater
SSH_KEY=/etc/ssh/splash-updater_ed25519

log() { printf '\033[1;34m[splash-updater-setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[splash-updater-setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    die "Must run as root: sudo bash $0"
fi

# 1. User
if id "$SU_USER" >/dev/null 2>&1; then
    log "User '$SU_USER' already exists."
else
    log "Creating user '$SU_USER'..."
    # /bin/bash, not /usr/sbin/nologin: sshd's ForceCommand runs the forced
    # command via the user's login shell (execve "$shell -c $cmd"), and
    # nologin refuses to exec ANYTHING. The lockdown is enforced elsewhere:
    # password is locked (no -p, --system), authorized_keys carries
    # restrict + ForceCommand so the only thing this shell can ever
    # execute is /usr/local/libexec/accept-splash.
    useradd --system --create-home --home-dir "/home/$SU_USER" --shell /bin/bash "$SU_USER"
    passwd -l "$SU_USER" >/dev/null
fi

# 2. Staging dir
log "Ensuring $STAGING_DIR exists and is owned by $SU_USER..."
install -d -o "$SU_USER" -g "$SU_USER" -m 0700 "$STAGING_DIR"

# 3. Helpers
log "Installing $ACCEPT_DST..."
install -d -m 0755 "$LIBEXEC"
install -o root -g root -m 0755 "$SCRIPT_DIR/accept-splash.sh" "$ACCEPT_DST"
log "Installing $INSTALL_DST..."
install -o root -g root -m 0755 "$SCRIPT_DIR/install-staged-splash.sh" "$INSTALL_DST"

# 4. Sudoers — narrow grant, NO arguments allowed.
log "Writing $SUDOERS_DST..."
tmp_sudo=$(mktemp)
cat > "$tmp_sudo" <<EOF
# Allow the splash-updater user to invoke ONLY the no-args installer.
# This pairs with the authorized_keys ForceCommand to ensure the only
# code path that can write /home/kiosk/splash.png is via accept-splash.
$SU_USER ALL=(root) NOPASSWD: /usr/local/libexec/install-staged-splash
EOF
visudo -cf "$tmp_sudo" || die "sudoers file failed visudo check"
install -o root -g root -m 0440 "$tmp_sudo" "$SUDOERS_DST"
rm -f "$tmp_sudo"

# 5. SSH key
if [[ ! -f "$SSH_KEY" ]]; then
    log "Generating SSH keypair at $SSH_KEY..."
    ssh-keygen -t ed25519 -N '' -C 'splash-updater@displaypi' -f "$SSH_KEY"
else
    log "SSH key $SSH_KEY already exists; reusing."
fi
chmod 0600 "$SSH_KEY"
chmod 0644 "${SSH_KEY}.pub"

# 6. authorized_keys with ForceCommand. `restrict` is the modern
# default-deny set; we still spell out the no-* options for older sshd
# versions and clarity.
SU_HOME=$(getent passwd "$SU_USER" | cut -d: -f6)
install -d -o "$SU_USER" -g "$SU_USER" -m 0700 "$SU_HOME/.ssh"
ak="$SU_HOME/.ssh/authorized_keys"
pub_key=$(cut -d' ' -f1-2 < "${SSH_KEY}.pub")
printf '%s %s\n' \
    'command="/usr/local/libexec/accept-splash",restrict,no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty' \
    "$pub_key" > "$ak"
chown "$SU_USER:$SU_USER" "$ak"
chmod 0600 "$ak"

# 7. Print volunteer-bundle info.
host=$(hostname)
pi_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

cat <<INFO

============================================================
splash-updater setup complete.
============================================================

To create a volunteer bundle, copy these to a USB stick or email:

  Private key file (rename to splash-updater on the volunteer machine):
$(sed 's/^/    /' "$SSH_KEY")

  Public key (already installed in authorized_keys, for reference):
    $(cat "${SSH_KEY}.pub")

  Connection details for the volunteer:
    Host: ${pi_ip:-$host} (or '$host' if their DNS resolves it)
    User: $SU_USER
    Default port: 22

To replace the splash on the kiosk, the volunteer runs:

  macOS/Linux:
    dev/splash-replace.sh <path/to/their-image.png>

  Windows:
    powershell -ExecutionPolicy Bypass -File dev\\splash-replace.ps1 <path>

Both scripts validate locally first (friendlier errors) then upload to
this Pi. The Pi re-validates on receipt and restarts the kiosk so the
new splash appears within ~2 seconds.

============================================================
INFO
