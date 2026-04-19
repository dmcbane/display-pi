#!/bin/bash
#
# deploy.sh — Push repo to the Pi and reload the kiosk service
#
# Usage: deploy.sh [host]
# Default host: displaypi (override with KIOSK_HOST env or argument)

set -euo pipefail

HOST="${1:-${KIOSK_HOST:-displaypi}}"
KIOSK_USER="${KIOSK_USER:-kiosk}"
REMOTE_DIR="/home/${KIOSK_USER}/display-pi"
SSH_USER="${SSH_USER:-$(whoami)}"

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Verify we can reach the Pi
log "Testing SSH to ${SSH_USER}@${HOST}..."
ssh -o ConnectTimeout=5 "${SSH_USER}@${HOST}" true || die "Cannot reach ${HOST}"

# Sync files (exclude .git and dev/ — dev tools stay on workstation)
log "Syncing to ${HOST}:${REMOTE_DIR}..."
rsync -avz --delete \
    --exclude='.git/' \
    --exclude='dev/' \
    --exclude='tests/' \
    --exclude='*.swp' \
    --exclude='*.swo' \
    --exclude='__pycache__/' \
    "${REPO_ROOT}/" "${SSH_USER}@${HOST}:${REMOTE_DIR}/"

# Fix ownership if deploying as non-kiosk user
log "Fixing ownership..."
ssh "${SSH_USER}@${HOST}" "sudo chown -R ${KIOSK_USER}:${KIOSK_USER} ${REMOTE_DIR}/"

# Symlink install files into expected locations
log "Installing files..."
ssh "${SSH_USER}@${HOST}" bash <<REMOTE
set -euo pipefail

# Ensure bin directory exists
sudo -u ${KIOSK_USER} mkdir -p /home/${KIOSK_USER}/bin

# Link player.sh
sudo ln -sf ${REMOTE_DIR}/install/player.sh /home/${KIOSK_USER}/bin/player.sh
sudo chown -h ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/bin/player.sh

# Link assess.sh
sudo ln -sf ${REMOTE_DIR}/install/assess.sh /home/${KIOSK_USER}/bin/assess.sh
sudo chown -h ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/bin/assess.sh

# Install service file if changed
if ! diff -q ${REMOTE_DIR}/install/kiosk.service /home/${KIOSK_USER}/.config/systemd/user/kiosk.service &>/dev/null 2>&1; then
    sudo -u ${KIOSK_USER} mkdir -p /home/${KIOSK_USER}/.config/systemd/user
    sudo cp ${REMOTE_DIR}/install/kiosk.service /home/${KIOSK_USER}/.config/systemd/user/kiosk.service
    sudo chown ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/.config/systemd/user/kiosk.service
    echo "Service file updated"
fi

# Install nginx config if changed
if ! diff -q ${REMOTE_DIR}/install/nginx.conf /etc/nginx/nginx.conf &>/dev/null 2>&1; then
    sudo cp ${REMOTE_DIR}/install/nginx.conf /etc/nginx/nginx.conf
    sudo nginx -t && sudo systemctl reload nginx
    echo "nginx config updated and reloaded"
fi

# Install splash image if present and different
if [[ -f ${REMOTE_DIR}/images/splash.png ]]; then
    if ! diff -q ${REMOTE_DIR}/images/splash.png /home/${KIOSK_USER}/splash.png &>/dev/null 2>&1; then
        sudo cp ${REMOTE_DIR}/images/splash.png /home/${KIOSK_USER}/splash.png
        sudo chown ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/splash.png
        echo "Splash image updated"
    fi
fi
REMOTE

# Reload kiosk service
log "Reloading kiosk service..."
ssh "${SSH_USER}@${HOST}" bash <<REMOTE
KIOSK_UID=\$(id -u ${KIOSK_USER})
sudo -u ${KIOSK_USER} XDG_RUNTIME_DIR="/run/user/\${KIOSK_UID}" \
    systemctl --user daemon-reload
sudo -u ${KIOSK_USER} XDG_RUNTIME_DIR="/run/user/\${KIOSK_UID}" \
    systemctl --user restart kiosk.service
echo "Kiosk service restarted"
REMOTE

log "Deploy complete to ${HOST}"
