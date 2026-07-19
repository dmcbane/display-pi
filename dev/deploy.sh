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
    --exclude='*-volunteer.*' \
    "${REPO_ROOT}/" "${HOST}:${REMOTE_DIR}/"

# Symlink install files into expected locations.
# TODO: logrotate / PipeWire / splash.png blocks below silently re-copy on
# every deploy because their diff/-f checks run as rpi and can't read
# /home/kiosk (mode 0700). See docs/dev-journal/2026-04-25-deploy-stale-diffs.md.
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

# Install become-kiosk helper (system-wide, so any SSH/deploy user can use it)
if ! diff -q ${REMOTE_DIR}/install/become-kiosk.sh /usr/local/bin/become-kiosk &>/dev/null; then
    sudo install -m 0755 -o root -g root ${REMOTE_DIR}/install/become-kiosk.sh /usr/local/bin/become-kiosk
    echo "become-kiosk helper updated"
fi

# Install kiosk-status helper (system-wide status command for SSH users)
if ! diff -q ${REMOTE_DIR}/install/kiosk-status.sh /usr/local/bin/kiosk-status &>/dev/null; then
    sudo install -m 0755 -o root -g root ${REMOTE_DIR}/install/kiosk-status.sh /usr/local/bin/kiosk-status
    echo "kiosk-status helper updated"
fi

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

# Ensure the web-manager nginx include dir exists and, for an existing web
# install with no site file yet, seed the default HTTP block — BEFORE the
# nginx.conf reload below, so the new wildcard-include nginx.conf never reloads
# to an empty dir and drops the manager's server block mid-deploy. A TLS site
# file (from kiosk-web-tls-setup.sh) is left untouched.
sudo mkdir -p /etc/nginx/kiosk-web-site.d
if [[ -d /opt/kiosk-web ]] && ! ls /etc/nginx/kiosk-web-site.d/*.conf &>/dev/null; then
    sudo install -m 0644 -o root -g root \
        ${REMOTE_DIR}/install/kiosk-web-site-http.conf /etc/nginx/kiosk-web-site.d/site.conf
    echo "seeded default HTTP web-manager site block"
fi

# Install nginx config if changed. Rendered through render-nginx-conf.sh with
# the RTMP app/CIDRs persisted in /etc/default/kiosk, so a deploy never
# reverts values configured at setup time (install/nginx.conf is the
# structural template, not the literal file).
RENDERED_NGINX=\$(mktemp)
# sudo: the template lives under /home/kiosk (mode 0700), unreadable to the
# deploy user directly.
sudo bash ${REMOTE_DIR}/install/render-nginx-conf.sh ${REMOTE_DIR}/install/nginx.conf > "\$RENDERED_NGINX"
if ! diff -q "\$RENDERED_NGINX" /etc/nginx/nginx.conf &>/dev/null 2>&1; then
    sudo cp "\$RENDERED_NGINX" /etc/nginx/nginx.conf
    sudo nginx -t && sudo systemctl reload nginx
    echo "nginx config updated and reloaded"
fi
rm -f "\$RENDERED_NGINX"

# Symlink the splash images from the deployed repo — no copies, single source
# of truth, exactly like the bin/ scripts above. /home/kiosk/splash.d is the
# rotation folder; /home/kiosk/splash.png is the single fallback. Created via
# sudo (root), so the 0700 /home/kiosk is no obstacle (the old copy blocks
# gated on a test the deploy user couldn't pass, so they silently no-op'd).
# A pre-existing *real* splash.d dir (older layout) is removed first so the
# symlink takes its place. The volunteer drop-in lives inside the symlinked
# repo folder and is protected from --delete by the top-level rsync exclude.
if [ -d /home/${KIOSK_USER}/splash.d ] && [ ! -L /home/${KIOSK_USER}/splash.d ]; then
    sudo rm -rf /home/${KIOSK_USER}/splash.d
fi
sudo ln -sfn ${REMOTE_DIR}/images/splash.d /home/${KIOSK_USER}/splash.d
sudo chown -h ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/splash.d
sudo ln -sf ${REMOTE_DIR}/images/splash.png /home/${KIOSK_USER}/splash.png
sudo chown -h ${KIOSK_USER}:${KIOSK_USER} /home/${KIOSK_USER}/splash.png
echo "Splash images symlinked"
REMOTE

# Update kiosk-web app if the web manager has been set up on this Pi
ssh "${HOST}" bash <<REMOTE
set -euo pipefail
if [[ -d /opt/kiosk-web ]]; then
    # Ensure the rotatable-token state dir exists (older installs predate it).
    if [[ ! -d /var/lib/kiosk-web ]]; then
        sudo install -d -m 0700 -o kiosk-web -g kiosk-web /var/lib/kiosk-web
        echo "created /var/lib/kiosk-web token store"
    fi
    # sudo: the repo copy is under /home/kiosk (0700) — an unreadable diff
    # "fails", which reinstalled and restarted kiosk-web on EVERY deploy
    # (a ~1s 502 for anyone mid-session in the manager).
    if ! sudo diff -q ${REMOTE_DIR}/web/kiosk_manager.py /opt/kiosk-web/kiosk_manager.py &>/dev/null; then
        sudo install -m 0644 -o root -g root \
            ${REMOTE_DIR}/web/kiosk_manager.py /opt/kiosk-web/kiosk_manager.py
        sudo systemctl restart kiosk-web
        echo "kiosk-web app updated and restarted"
    fi
fi
REMOTE

# Reload kiosk service
log "Reloading kiosk service..."
ssh "${HOST}" bash <<REMOTE
KIOSK_UID=\$(id -u ${KIOSK_USER})
# systemctl --user needs DBUS_SESSION_BUS_ADDRESS as well as XDG_RUNTIME_DIR,
# or it fails with "Failed to connect to user scope bus" (become-kiosk.sh,
# 2026-06-13). The deploy sudoers grants SETENV so both survive.
sudo -u ${KIOSK_USER} XDG_RUNTIME_DIR="/run/user/\${KIOSK_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\${KIOSK_UID}/bus" \
    systemctl --user daemon-reload
sudo -u ${KIOSK_USER} XDG_RUNTIME_DIR="/run/user/\${KIOSK_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\${KIOSK_UID}/bus" \
    systemctl --user restart kiosk.service
echo "Kiosk service restarted"
REMOTE

log "Deploy complete to ${HOST}"
