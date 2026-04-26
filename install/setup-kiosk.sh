#!/bin/bash
#
# Raspberry Pi Worship Stream Kiosk - Setup Script
#
# Sets up a Pi 4 or Pi 5 (Raspberry Pi OS Lite, Bookworm, 64-bit) as a
# lobby/overflow display that:
#
# Pi 4 is the reference platform; Pi 5 is supported with caveats — see
# docs/setup-guide.md ("Pi 4 vs Pi 5 — known differences").
#   - Receives an RTMP push from the ATEM Mini Pro
#   - Shows a splash image when the stream is idle
#   - Auto-switches to the live stream when it arrives
#   - Auto-recovers from crashes; boots straight into kiosk mode
#
# Run as a sudo-capable regular user (NOT root directly).
#
# Idempotent: safe to re-run. Any file it modifies is backed up with
# a timestamped .bak-YYYYMMDD-HHMMSS suffix before changes.

set -euo pipefail

# =============================================================================
# CONFIGURATION  -  edit these before running
# =============================================================================

# All values below can be overridden by exporting the matching env var
# before running this script (e.g. STREAM_KEY=foo bash setup-kiosk.sh).

# Network CIDRs allowed to push RTMP to this Pi. Tighten to the ATEM's IP
# (e.g. "192.168.1.42/32") once you know it's stable. Pass as a
# space-separated string when overriding via env.
if [[ -n "${RTMP_ALLOW_PUBLISH_CIDRS:-}" ]]; then
    read -r -a RTMP_ALLOW_PUBLISH_CIDRS <<< "$RTMP_ALLOW_PUBLISH_CIDRS"
else
    RTMP_ALLOW_PUBLISH_CIDRS=("192.168.0.0/16" "10.0.0.0/8")
fi

# The stream key the ATEM will push with. Must match ATEM's config.
STREAM_KEY="${STREAM_KEY:-church242}"

# The RTMP application name (the path component before the key).
RTMP_APP="${RTMP_APP:-live}"

# Splash image text (used to generate a placeholder PNG).
# Replace /home/<kiosk-user>/splash.png with your branded image after setup.
SPLASH_TEXT="${SPLASH_TEXT:-Service will begin shortly}"

# Kiosk user. Created if missing. Do not change after first run.
KIOSK_USER="${KIOSK_USER:-kiosk}"

# Deploy/SSH user — the account that runs `dev/deploy.sh` from the
# workstation. Gets a narrow sudoers whitelist for the deploy operations.
# Defaults to the user invoking this script (since you typically run
# setup-kiosk.sh as the same user that will deploy from the workstation).
DEPLOY_USER="${SUDO_USER:-$USER}"

# mpv volume for the lobby/overflow display (0-100).
PLAYBACK_VOLUME="${PLAYBACK_VOLUME:-80}"

# =============================================================================
# Below this line you shouldn't need to edit.
# =============================================================================

readonly STAMP=$(date +%Y%m%d-%H%M%S)
readonly SCRIPT_NAME=$(basename "$0")

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

# Back up a file before modifying, if it exists and we haven't backed it up yet
# in this run.
backup_once() {
    local file="$1"
    if [[ -f "$file" && ! -f "${file}.bak-${STAMP}" ]]; then
        sudo cp -a "$file" "${file}.bak-${STAMP}"
        log "Backed up $file -> ${file}.bak-${STAMP}"
    fi
}

require_root_capable() {
    if [[ $EUID -eq 0 ]]; then
        die "Don't run this as root. Run as a regular sudo-capable user."
    fi
    if ! sudo -n true 2>/dev/null; then
        log "This script needs sudo. You'll be prompted for your password."
        sudo -v || die "sudo authentication failed"
    fi
    # Keep sudo alive for the duration of the script
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
}

confirm_os() {
    if ! grep -qi 'raspbian\|raspberry pi os\|debian' /etc/os-release; then
        warn "This doesn't look like Raspberry Pi OS. Continuing anyway."
    fi
    if ! grep -q 'bookworm' /etc/os-release 2>/dev/null; then
        warn "Not Bookworm. Paths like /boot/firmware may differ."
    fi
}

# =============================================================================
# Step 1: Packages
# =============================================================================
install_packages() {
    log "Updating apt and installing packages..."
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        cage mpv seatd \
        libnginx-mod-rtmp nginx \
        watchdog cec-utils \
        ffmpeg imagemagick fonts-dejavu-core \
        ca-certificates curl logrotate cron \
        pipewire pipewire-audio wireplumber
    log "Packages installed."
}

# =============================================================================
# Step 2: Kiosk user
# =============================================================================
create_kiosk_user() {
    if id "$KIOSK_USER" &>/dev/null; then
        log "User '$KIOSK_USER' already exists."
    else
        log "Creating user '$KIOSK_USER'..."
        sudo useradd -m -s /bin/bash "$KIOSK_USER"
    fi

    # Ensure required group memberships (idempotent)
    for group in video render input seat audio; do
        if getent group "$group" >/dev/null; then
            sudo usermod -aG "$group" "$KIOSK_USER"
        else
            warn "Group '$group' does not exist on this system; skipping."
        fi
    done

    # Enable lingering so user services start at boot without login
    sudo loginctl enable-linger "$KIOSK_USER"
    log "User '$KIOSK_USER' ready."
}

# =============================================================================
# Step 3: seatd (required for cage on Bookworm Lite without a full session manager)
# =============================================================================
enable_seatd() {
    log "Enabling seatd..."
    sudo systemctl enable --now seatd.service
}

# =============================================================================
# Step 4: nginx with RTMP module
# =============================================================================
configure_nginx_rtmp() {
    log "Configuring nginx RTMP..."
    backup_once /etc/nginx/nginx.conf

    # Build the allow-publish lines from the config array
    local allow_lines=""
    for cidr in "${RTMP_ALLOW_PUBLISH_CIDRS[@]}"; do
        allow_lines+="            allow publish ${cidr};"$'\n'
    done

    sudo tee /etc/nginx/nginx.conf > /dev/null <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        application ${RTMP_APP} {
            live on;
            record off;
${allow_lines}            deny publish all;

            allow play 127.0.0.1;
            deny play all;
        }
    }
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
    gzip on;
}
EOF

    sudo nginx -t || die "nginx config test failed. Check /etc/nginx/nginx.conf"
    sudo systemctl enable nginx
    sudo systemctl restart nginx
    log "nginx RTMP listening on :1935 (app=${RTMP_APP}, key=${STREAM_KEY})"
}

# =============================================================================
# Step 5: Boot config  (KMS-correct, minimal, Bookworm-safe)
# =============================================================================
#
# Bookworm uses the KMS graphics driver. Legacy firmware directives like
# hdmi_force_hotplug, disable_overscan, and gpu_mem are ignored under KMS --
# and hdmi_force_hotplug in particular can wedge the firmware boot stage
# (rainbow screen hang). We therefore avoid them entirely.
#
# Instead:
#   - vc4.force_hotplug=1   goes in cmdline.txt (kernel parameter read by
#                           the vc4-kms-v3d driver). Makes HDMI-0 always
#                           appear connected, so a TV powered off at Pi boot
#                           doesn't leave us with no display modes.
#   - consoleblank=0        prevents the framebuffer console from blanking
#                           before cage+mpv take over the display.
#
# In config.txt we add:
#   - dtparam=watchdog=on   enables the hardware watchdog device used below.
#   - dtoverlay=disable-bt  frees the primary UART and saves a little power
#                           (this kiosk doesn't need Bluetooth).
#
# These additions are wrapped in marker comments so the script can remove
# and re-add them idempotently on re-runs.
# =============================================================================
configure_boot() {
    local config_file
    if [[ -f /boot/firmware/config.txt ]]; then
        config_file=/boot/firmware/config.txt
    elif [[ -f /boot/config.txt ]]; then
        config_file=/boot/config.txt
    else
        die "Could not find config.txt in /boot/firmware or /boot"
    fi

    local cmdline_file
    if [[ -f /boot/firmware/cmdline.txt ]]; then
        cmdline_file=/boot/firmware/cmdline.txt
    elif [[ -f /boot/cmdline.txt ]]; then
        cmdline_file=/boot/cmdline.txt
    else
        die "Could not find cmdline.txt"
    fi

    local marker_start="# === kiosk-setup BEGIN ==="
    local marker_end="# === kiosk-setup END ==="

    # --- config.txt ---
    log "Configuring $config_file ..."
    backup_once "$config_file"

    # Strip any prior kiosk-setup block (including broken versions from
    # earlier iterations of this script that used legacy hdmi_* options).
    sudo sed -i "/${marker_start}/,/${marker_end}/d" "$config_file"

    sudo tee -a "$config_file" > /dev/null <<EOF
${marker_start}
# Hardware watchdog for auto-recovery from kernel hangs
dtparam=watchdog=on
# Free the UART and save a little power; kiosk doesn't use Bluetooth
dtoverlay=disable-bt
${marker_end}
EOF

    # --- cmdline.txt (single-line file, handle with care) ---
    log "Configuring $cmdline_file ..."
    backup_once "$cmdline_file"

    # Read the current line and normalize whitespace
    local current
    current=$(sudo sed -n '/./{p;q}' "$cmdline_file")
    if [[ -z "$current" ]]; then
        die "cmdline.txt appears empty; refusing to modify. Restore from image."
    fi
    current=$(echo "$current" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')

    local tokens_to_add=()
    # Use word-boundary match so we don't false-positive on substring matches
    if ! grep -qw 'consoleblank=0' <<<"$current"; then
        tokens_to_add+=("consoleblank=0")
    fi
    if ! grep -qE '(^| )vc4\.force_hotplug=' <<<"$current"; then
        tokens_to_add+=("vc4.force_hotplug=1")
    fi

    if (( ${#tokens_to_add[@]} > 0 )); then
        local new="${current} ${tokens_to_add[*]}"
        echo "$new" | sudo tee "$cmdline_file" > /dev/null
        log "Added to cmdline.txt: ${tokens_to_add[*]}"
    else
        log "cmdline.txt already has required kernel params."
    fi

    # Sanity check: cmdline.txt must be exactly one non-empty line
    local line_count
    line_count=$(grep -c . "$cmdline_file")
    if [[ "$line_count" -ne 1 ]]; then
        warn "cmdline.txt has $line_count non-empty lines (should be 1)."
        warn "Restoring backup to avoid boot failure."
        sudo cp -a "${cmdline_file}.bak-${STAMP}" "$cmdline_file"
        die "cmdline.txt restored from backup. Investigate before retrying."
    fi
}

# =============================================================================
# Step 6: Splash image
# =============================================================================
create_splash() {
    local splash_path="/home/${KIOSK_USER}/splash.png"
    if [[ -f "$splash_path" ]]; then
        log "Splash image already exists at $splash_path (leaving it alone)."
        return
    fi
    log "Generating placeholder splash image..."
    sudo -u "$KIOSK_USER" convert -size 1920x1080 xc:black \
        -gravity center -pointsize 72 -fill white \
        -font DejaVu-Sans \
        -annotate 0 "$SPLASH_TEXT" \
        "$splash_path"
    log "Splash created at $splash_path (replace with your branded image anytime)."
}

# =============================================================================
# Step 7: Player script
# =============================================================================
create_player_script() {
    local player_dir="/home/${KIOSK_USER}/bin"
    local player_script="${player_dir}/player.sh"
    local stream_url="rtmp://127.0.0.1/${RTMP_APP}/${STREAM_KEY}"

    log "Installing player script to $player_script ..."
    sudo -u "$KIOSK_USER" mkdir -p "$player_dir"

    sudo -u "$KIOSK_USER" tee "$player_script" > /dev/null <<EOF
#!/bin/bash
#
# Kiosk player loop:
#   - shows splash while the stream is idle
#   - starts mpv when the stream goes live
#   - returns to splash when the stream ends / mpv exits
#
# Generated by setup-kiosk.sh on ${STAMP}

set -u

STREAM_URL="${stream_url}"
SPLASH_IMAGE="/home/${KIOSK_USER}/splash.png"
VOLUME=${PLAYBACK_VOLUME}

show_splash() {
    mpv --fullscreen --really-quiet --loop \\
        --image-display-duration=inf \\
        --no-input-default-bindings \\
        --no-audio \\
        "\$SPLASH_IMAGE" &
    echo \$!
}

stream_live() {
    # On the Pi, RTMP handshake + ffprobe analyzeduration commonly takes
    # 3-6s before any codec_type line appears. Cap at 8s and tighten
    # analyzeduration/probesize so the on-air case returns as soon as
    # the first frame is parsed.
    timeout 8 ffprobe -v quiet \\
        -analyzeduration 1500000 -probesize 500000 \\
        -show_streams "\$STREAM_URL" 2>/dev/null \\
        | grep -q codec_type
}

while true; do
    if ! stream_live; then
        SPLASH_PID=\$(show_splash)
        while ! stream_live; do
            sleep 3
        done
        kill "\$SPLASH_PID" 2>/dev/null || true
        wait "\$SPLASH_PID" 2>/dev/null || true
    fi

    mpv --fullscreen \\
        --hwdec=v4l2m2m-copy \\
        --vo=gpu \\
        --profile=low-latency \\
        --cache=yes --demuxer-max-bytes=4MiB \\
        --audio-device=alsa/plughw:CARD=vc4hdmi0,DEV=0 \\
        --volume="\$VOLUME" \\
        --no-osc --no-osd-bar \\
        --no-input-default-bindings \\
        --really-quiet \\
        --msg-level=all=warn \\
        "\$STREAM_URL" || true

    sleep 2
done
EOF

    sudo chmod +x "$player_script"
    sudo chown "$KIOSK_USER:$KIOSK_USER" "$player_script"
    log "Player script installed."
}

# =============================================================================
# Step 8: systemd user service
# =============================================================================
install_kiosk_service() {
    local service_dir="/home/${KIOSK_USER}/.config/systemd/user"
    local service_file="${service_dir}/kiosk.service"

    log "Installing systemd user service..."
    sudo -u "$KIOSK_USER" mkdir -p "$service_dir"

    sudo -u "$KIOSK_USER" tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Worship stream kiosk display
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WLR_LIBINPUT_NO_DEVICES=1
ExecStart=/usr/bin/cage -s -- /home/${KIOSK_USER}/bin/player.sh
Restart=always
RestartSec=3
StartLimitIntervalSec=0

[Install]
WantedBy=default.target
EOF

    # Enable and reload as the kiosk user
    local kiosk_uid
    kiosk_uid=$(id -u "$KIOSK_USER")
    sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/${kiosk_uid}" \
        systemctl --user daemon-reload
    sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/${kiosk_uid}" \
        systemctl --user enable kiosk.service
    log "Kiosk service enabled (starts automatically on next boot)."
}

# =============================================================================
# Step 9: Watchdog
# =============================================================================
configure_watchdog() {
    log "Configuring hardware watchdog..."
    backup_once /etc/watchdog.conf

    # Idempotent: remove any prior kiosk-setup block and append fresh
    local marker_start="# === kiosk-setup BEGIN ==="
    local marker_end="# === kiosk-setup END ==="
    sudo sed -i "/${marker_start}/,/${marker_end}/d" /etc/watchdog.conf

    sudo tee -a /etc/watchdog.conf > /dev/null <<EOF
${marker_start}
watchdog-device = /dev/watchdog
max-load-1 = 24
realtime = yes
priority = 1
${marker_end}
EOF

    sudo systemctl enable --now watchdog
    log "Watchdog enabled."
}

# =============================================================================
# Step 10: PipeWire client config (eliminates runtime log noise)
# =============================================================================
configure_pipewire() {
    local src="/usr/share/pipewire/client.conf"
    local dst="/home/${KIOSK_USER}/.config/pipewire/client.conf"

    if [[ -f "$src" ]]; then
        if [[ ! -f "$dst" ]]; then
            log "Installing PipeWire client.conf for kiosk user..."
            sudo -u "$KIOSK_USER" mkdir -p "$(dirname "$dst")"
            sudo cp "$src" "$dst"
            sudo chown "$KIOSK_USER:$KIOSK_USER" "$dst"
            log "PipeWire client.conf installed at $dst."
        else
            log "PipeWire client.conf already present at $dst."
        fi
    else
        log "No system PipeWire client.conf at $src; skipping copy."
    fi

    # Enable PipeWire/WirePlumber for the kiosk user. mpv talks directly to
    # ALSA (alsa/plughw:CARD=vc4hdmi0,DEV=0) so audio does not depend on
    # PipeWire — but we keep the stack running for assess.sh's "PipeWire sink
    # available" probe and to keep option B (default-sink rule) viable.
    # See docs/journal/2026-04-25-hdmi-audio-routing.md.
    local kiosk_uid
    kiosk_uid=$(id -u "$KIOSK_USER")
    sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/${kiosk_uid}" \
        systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || \
        warn "Could not enable pipewire user services (will try on next reboot)."
}

# =============================================================================
# Step 10b: Deploy sudoers whitelist
# =============================================================================
#
# Installs /etc/sudoers.d/kiosk-deploy from install/kiosk-deploy.sudoers so
# `dev/deploy.sh` can run its specific commands without prompting for a
# password every time. Validates the file with `visudo -cf` before copying
# into place — a syntax error in /etc/sudoers.d/ can lock the user out of
# sudo entirely. See docs/journal/2026-04-25-hdmi-audio-routing.md.
configure_deploy_sudoers() {
    local src
    src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/kiosk-deploy.sudoers"
    local dst=/etc/sudoers.d/kiosk-deploy

    if [[ ! -f "$src" ]]; then
        warn "kiosk-deploy.sudoers template not found at $src; skipping."
        return
    fi

    log "Configuring deploy sudoers whitelist for user '$DEPLOY_USER'..."

    # Substitute the deploy username into a temp file, validate, then install.
    local tmp
    tmp=$(mktemp)
    trap "rm -f '$tmp'" RETURN
    sed "s/__DEPLOY_USER__/${DEPLOY_USER}/g" "$src" > "$tmp"

    if ! sudo visudo -cf "$tmp" >/dev/null; then
        die "Generated sudoers fragment failed visudo validation. Refusing to install $dst."
    fi

    sudo install -o root -g root -m 0440 "$tmp" "$dst"
    log "Installed $dst (deploy user: $DEPLOY_USER)."
}

# =============================================================================
# Step 11: Log rotation for /tmp/player.log
# =============================================================================
configure_logrotate() {
    local src
    src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/logrotate-kiosk"
    local dst=/etc/logrotate.d/kiosk-player

    if [[ ! -f "$src" ]]; then
        warn "logrotate-kiosk template not found at $src; skipping."
        return
    fi

    log "Installing logrotate config for player.log..."
    backup_once "$dst"
    sudo cp "$src" "$dst"
    sudo chmod 644 "$dst"
    log "logrotate config installed at $dst (1MB cap, 3 rotations)."
}

# =============================================================================
# Step 12: Healthcheck cron (pings external monitor every 5 min)
# =============================================================================
configure_healthcheck() {
    local src
    src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/healthcheck.sh"
    local kiosk_bin="/home/${KIOSK_USER}/bin"
    local installed="${kiosk_bin}/healthcheck.sh"
    local conf=/etc/kiosk-healthcheck.conf
    local cron=/etc/cron.d/kiosk-healthcheck

    if [[ ! -x "$src" ]]; then
        warn "healthcheck.sh not found at $src; skipping."
        return
    fi

    log "Installing healthcheck.sh..."
    sudo -u "$KIOSK_USER" mkdir -p "$kiosk_bin"
    sudo cp "$src" "$installed"
    sudo chown "$KIOSK_USER:$KIOSK_USER" "$installed"
    sudo chmod +x "$installed"

    if [[ ! -f "$conf" ]]; then
        log "Creating placeholder $conf — fill in HEALTHCHECK_URL to activate."
        sudo tee "$conf" > /dev/null <<'EOF'
# Kiosk healthcheck config. Fill in the URL from healthchecks.io (or similar).
# The URL is pinged every 5 min by /etc/cron.d/kiosk-healthcheck.
# Empty URL = silently disabled.
HEALTHCHECK_URL=
HEALTHCHECK_TIMEOUT=10
EOF
        sudo chmod 644 "$conf"
    else
        log "$conf already exists; leaving it alone."
    fi

    log "Installing cron entry at $cron (every 5 min)..."
    sudo tee "$cron" > /dev/null <<EOF
# Kiosk healthcheck — pings HEALTHCHECK_URL every 5 min.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * ${KIOSK_USER} ${installed}
EOF
    sudo chmod 644 "$cron"
    log "Healthcheck cron installed."
}

# =============================================================================
# Main
# =============================================================================
main() {
    require_root_capable
    confirm_os

    log "Starting kiosk setup (backup suffix: .bak-${STAMP})"

    install_packages
    create_kiosk_user
    enable_seatd
    configure_nginx_rtmp
    configure_boot
    create_splash
    create_player_script
    install_kiosk_service
    configure_watchdog
    configure_pipewire
    configure_deploy_sudoers
    configure_logrotate
    configure_healthcheck

    cat <<EOF

$(printf '\033[1;32m')==============================================================
Setup complete.
==============================================================$(printf '\033[0m')

Next steps:

  1. Configure the ATEM Mini Pro to push RTMP to:
        Server:     rtmp://<THIS_PI_IP>/${RTMP_APP}
        Stream key: ${STREAM_KEY}
     Use Blackmagic's Streaming.xml generator to add this as a
     custom destination in ATEM Software Control.

  2. Reboot to activate boot config and start the kiosk:
        sudo reboot

  3. After reboot, verify:
        # nginx RTMP listener
        sudo ss -tlnp | grep 1935

        # Kiosk service status
        sudo machinectl shell ${KIOSK_USER}@ /bin/bash \\
             -c "systemctl --user status kiosk.service"

        # Live player logs
        sudo journalctl -f --user-unit=kiosk.service -M ${KIOSK_USER}@

  4. Test the full stream path WITHOUT the ATEM (from another machine):
        ffmpeg -re -f lavfi -i testsrc=size=1920x1080:rate=30 \\
               -f lavfi -i sine=frequency=440 \\
               -c:v libx264 -preset veryfast -tune zerolatency \\
               -c:a aac -f flv rtmp://<PI_IP>/${RTMP_APP}/${STREAM_KEY}

Replace /home/${KIOSK_USER}/splash.png with your own branded image
whenever you like; the kiosk picks it up on the next idle period.

EOF
}

main "$@"
