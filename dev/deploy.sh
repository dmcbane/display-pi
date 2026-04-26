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

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Verify we can reach the Pi (user comes from ssh config)
log "Testing SSH to ${HOST}..."
ssh -o ConnectTimeout=5 "${HOST}" true || die "Cannot reach ${HOST}"

# Sync files (exclude .git and dev/ — dev tools stay on workstation)
log "Syncing to ${HOST}:${REMOTE_DIR}..."
rsync -avz --delete \
    --rsync-path="sudo -u ${KIOSK_USER} rsync" \
    --exclude='.git/' \
    --exclude='.claude/' \
    --exclude='dev/' \
    --exclude='tests/' \
    --exclude='*.swp' \
    --exclude='*.swo' \
    --exclude='__pycache__/' \
    "${REPO_ROOT}/" "${HOST}:${REMOTE_DIR}/"

# Symlink install files into expected locations.
# TODO: logrotate / PipeWire / splash.png blocks below silently re-copy on
# every deploy because their diff/-f checks run as rpi and can't read
# /home/kiosk (mode 0700). See docs/journal/2026-04-25-deploy-stale-diffs.md.
log "Installing files..."
ssh "${HOST}" bash <<REMOTE
set -euo pipefail

# Ensure bin directory exists
sudo -u ${KIOSK_USER} mkdir -p /home/${KIOSK_USER}/bin

# Link player.sh
sudo ln -sf ${REMOTE_DIR}/install/player.sh /home/${KIOSK_USER}/bin/player.sh
sudo chown -h ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/bin/player.sh

# Link assess.sh
sudo ln -sf ${REMOTE_DIR}/install/assess.sh /home/${KIOSK_USER}/bin/assess.sh
sudo chown -h ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/bin/assess.sh

# Link healthcheck.sh
sudo ln -sf ${REMOTE_DIR}/install/healthcheck.sh /home/${KIOSK_USER}/bin/healthcheck.sh
sudo chown -h ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/bin/healthcheck.sh

# Link health-monitor.sh (writes /tmp/kiosk-health.json for overlay)
sudo ln -sf ${REMOTE_DIR}/diagnostics/health-monitor.sh /home/${KIOSK_USER}/bin/health-monitor.sh
sudo chown -h ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/bin/health-monitor.sh

# Install logrotate config if changed
if ! diff -q ${REMOTE_DIR}/install/logrotate-kiosk /etc/logrotate.d/kiosk-player &>/dev/null 2>&1; then
    sudo cp ${REMOTE_DIR}/install/logrotate-kiosk /etc/logrotate.d/kiosk-player
    sudo chmod 644 /etc/logrotate.d/kiosk-player
    echo "logrotate config updated"
fi

# Install PipeWire client.conf for kiosk user if missing
if [[ ! -f /home/${KIOSK_USER}/.config/pipewire/client.conf ]] && [[ -f /usr/share/pipewire/client.conf ]]; then
    sudo -u ${KIOSK_USER} mkdir -p /home/${KIOSK_USER}/.config/pipewire
    sudo cp /usr/share/pipewire/client.conf /home/${KIOSK_USER}/.config/pipewire/client.conf
    sudo chown ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/.config/pipewire/client.conf
    echo "PipeWire client.conf installed"
fi

# Install healthcheck cron entry if changed
HEALTHCHECK_CRON="# Kiosk healthcheck — pings HEALTHCHECK_URL every 5 min.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * ${KIOSK_USER} /home/${KIOSK_USER}/bin/healthcheck.sh"
if ! echo "\$HEALTHCHECK_CRON" | sudo diff -q - /etc/cron.d/kiosk-healthcheck &>/dev/null; then
    echo "\$HEALTHCHECK_CRON" | sudo tee /etc/cron.d/kiosk-healthcheck > /dev/null
    sudo chmod 644 /etc/cron.d/kiosk-healthcheck
    echo "healthcheck cron updated"
fi

# Create healthcheck config placeholder if missing
if [[ ! -f /etc/kiosk-healthcheck.conf ]]; then
    sudo tee /etc/kiosk-healthcheck.conf > /dev/null <<'CONF'
# Kiosk healthcheck config. Fill in the URL from healthchecks.io (or similar).
HEALTHCHECK_URL=
HEALTHCHECK_TIMEOUT=10
CONF
    sudo chmod 644 /etc/kiosk-healthcheck.conf
    echo "healthcheck config placeholder created"
fi

# Install service file if changed. Run diff/cp as kiosk: /home/kiosk is
# mode 0700, so the deploy user cannot read either side of the diff.
if ! sudo -u ${KIOSK_USER} diff -q ${REMOTE_DIR}/install/kiosk.service /home/${KIOSK_USER}/.config/systemd/user/kiosk.service &>/dev/null; then
    sudo -u ${KIOSK_USER} mkdir -p /home/${KIOSK_USER}/.config/systemd/user
    sudo -u ${KIOSK_USER} cp ${REMOTE_DIR}/install/kiosk.service /home/${KIOSK_USER}/.config/systemd/user/kiosk.service
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
ssh "${HOST}" bash <<REMOTE
KIOSK_UID=\$(id -u ${KIOSK_USER})
sudo -u ${KIOSK_USER} XDG_RUNTIME_DIR="/run/user/\${KIOSK_UID}" \
    systemctl --user daemon-reload
sudo -u ${KIOSK_USER} XDG_RUNTIME_DIR="/run/user/\${KIOSK_UID}" \
    systemctl --user restart kiosk.service
echo "Kiosk service restarted"
REMOTE

log "Deploy complete to ${HOST}"
