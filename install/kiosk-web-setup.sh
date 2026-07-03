#!/bin/bash
#
# kiosk-web-setup.sh — One-time setup for the volunteer web manager.
#
# Creates:
#   - kiosk-web system user (locked, no login)
#   - /var/lib/kiosk-splash/  (splash image storage, owned by kiosk-web)
#   - /opt/kiosk-web/         (app + virtualenv, owned by root)
#   - /etc/kiosk-web.conf     (TOKEN, SPLASH_DIR, KIOSK_USER — 0640 root:kiosk-web)
#   - /etc/sudoers.d/kiosk-web
#   - /etc/systemd/system/kiosk-web.service
#
# Also sets SPLASH_DIR in /etc/default/kiosk so player.sh reads from the
# web-managed directory rather than the repo symlink.
#
# Usage:
#   sudo bash install/kiosk-web-setup.sh
#
# Re-running is safe — every step is idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

KIOSK_USER="${KIOSK_USER:-kiosk}"
WEB_USER="kiosk-web"
SPLASH_DIR="/var/lib/kiosk-splash"
APP_DIR="/opt/kiosk-web"
CONF="/etc/kiosk-web.conf"
SUDOERS_DST="/etc/sudoers.d/kiosk-web"
SERVICE_DST="/etc/systemd/system/kiosk-web.service"

log() { printf '\033[1;34m[kiosk-web-setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[kiosk-web-setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root: sudo bash $0"

# 1. Create kiosk-web system user
if id "$WEB_USER" >/dev/null 2>&1; then
    log "User '$WEB_USER' already exists."
else
    log "Creating user '$WEB_USER'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$WEB_USER"
fi

# 2. Create splash directory
log "Ensuring $SPLASH_DIR exists..."
mkdir -p "$SPLASH_DIR"
chown "$WEB_USER:$WEB_USER" "$SPLASH_DIR"
chmod 0755 "$SPLASH_DIR"

# 2b. Create the app state dir for the rotatable token (0700, owned by web user).
#     The app runs as kiosk-web and cannot create anything under root-owned
#     /var/lib itself, so we make it here. The token file is written by the app
#     on first rotation; until then auth uses the seed TOKEN from $CONF.
STATE_DIR="/var/lib/kiosk-web"
log "Ensuring $STATE_DIR exists..."
mkdir -p "$STATE_DIR"
chown "$WEB_USER:$WEB_USER" "$STATE_DIR"
chmod 0700 "$STATE_DIR"

# 3. Seed with repo images if empty
if ! find "$SPLASH_DIR" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) \
        2>/dev/null | grep -q .; then
    if [[ -d "$REPO_DIR/images/splash.d" ]]; then
        log "Seeding $SPLASH_DIR with images from repo..."
        while IFS= read -r f; do
            dest="$SPLASH_DIR/$(basename "$f")"
            if [[ ! -f "$dest" ]]; then
                cp "$f" "$dest"
                chown "$WEB_USER:$WEB_USER" "$dest"
                echo "  copied $(basename "$f")"
            fi
        done < <(find "$REPO_DIR/images/splash.d" -maxdepth 1 \
                      \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) \
                      2>/dev/null | sort)
    fi
fi

# 4. Generate token and write /etc/kiosk-web.conf if not already set
if [[ -f "$CONF" ]] && grep -q '^TOKEN=' "$CONF" 2>/dev/null; then
    log "Auth token already set in $CONF."
    grep -q '^SPLASH_DIR='  "$CONF" || echo "SPLASH_DIR=$SPLASH_DIR"  >> "$CONF"
    grep -q '^KIOSK_USER='  "$CONF" || echo "KIOSK_USER=$KIOSK_USER"  >> "$CONF"
else
    log "Generating auth token..."
    TOKEN="$(openssl rand -hex 32)"
    printf '# Kiosk web manager config — keep this file private.\nTOKEN=%s\nSPLASH_DIR=%s\nKIOSK_USER=%s\n' \
        "$TOKEN" "$SPLASH_DIR" "$KIOSK_USER" > "$CONF"
    chmod 0640 "$CONF"
    chown "root:$WEB_USER" "$CONF"
    echo "  token written to $CONF"
fi

# 5. Set SPLASH_DIR in /etc/default/kiosk so player.sh uses the web-managed dir
if [[ ! -f /etc/default/kiosk ]]; then
    echo "SPLASH_DIR=$SPLASH_DIR" > /etc/default/kiosk
    chmod 0644 /etc/default/kiosk
    log "Created /etc/default/kiosk with SPLASH_DIR."
elif grep -q "^SPLASH_DIR=" /etc/default/kiosk; then
    log "SPLASH_DIR already set in /etc/default/kiosk."
else
    echo "SPLASH_DIR=$SPLASH_DIR" >> /etc/default/kiosk
    log "Added SPLASH_DIR to /etc/default/kiosk."
fi

# 6. Install app to /opt/kiosk-web/
log "Installing app to $APP_DIR..."
mkdir -p "$APP_DIR"
install -m 0644 -o root -g root "$REPO_DIR/web/kiosk_manager.py" "$APP_DIR/kiosk_manager.py"

# 7. Create virtualenv and install Python deps
if python3 -m venv --help >/dev/null 2>&1; then
    :
else
    die "python3-venv not available. Install: apt-get install python3-venv"
fi

if [[ ! -d "$APP_DIR/venv" ]]; then
    log "Creating Python virtualenv..."
    python3 -m venv "$APP_DIR/venv"
fi

log "Installing Python deps (flask, pillow)..."
"$APP_DIR/venv/bin/pip" install --quiet flask pillow

# 8. Install sudoers
log "Installing $SUDOERS_DST..."
install -m 0440 -o root -g root "$SCRIPT_DIR/kiosk-web.sudoers" "$SUDOERS_DST"
visudo -cf "$SUDOERS_DST" || { rm -f "$SUDOERS_DST"; die "Sudoers syntax error — removed."; }

# 9. Install and enable systemd service
log "Installing systemd service..."
install -m 0644 -o root -g root "$SCRIPT_DIR/kiosk-web.service" "$SERVICE_DST"
systemctl daemon-reload
systemctl enable kiosk-web
systemctl restart kiosk-web

# 9b. Bring the manager up over HTTPS with a locally-signed cert — the default,
#     no domain or internet required. Skipped if a site block already exists
#     (e.g. a Let's Encrypt or prior local setup) so we never clobber it; switch
#     explicitly later with kiosk-web-tls-local.sh or kiosk-web-tls-setup.sh.
SITE_DIR="/etc/nginx/kiosk-web-site.d"
mkdir -p "$SITE_DIR"
if ls "$SITE_DIR"/*.conf >/dev/null 2>&1; then
    log "nginx site block already present in $SITE_DIR — leaving it."
else
    log "Setting up HTTPS with a locally-signed certificate..."
    bash "$SCRIPT_DIR/kiosk-web-tls-local.sh"
fi

# 10. Print volunteer URL
TOKEN="$(grep '^TOKEN=' "$CONF" | cut -d= -f2-)"
PUBLIC_URL="$(grep '^PUBLIC_URL=' "$CONF" 2>/dev/null | cut -d= -f2-)"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_NAME="$(hostname -s 2>/dev/null || echo 'displaypi')"
BASE="${PUBLIC_URL:-https://${HOST_NAME}}"

log ""
log "Setup complete!"
log ""
log "  Volunteer URL:            ${BASE}/?token=${TOKEN}"
log "  Volunteer URL (IP):       https://${HOST_IP}/?token=${TOKEN}"
log ""
log "First time on each device, trust this Pi's CA for a warning-free padlock:"
log "  download  http://${HOST_IP}/rootCA.crt  and import it as a trusted root."
log ""
log "On your workstation, run: make volunteer-web-url"
log "That generates volunteer-kiosk.webloc (Mac) and volunteer-kiosk.url (Windows/Linux)."
