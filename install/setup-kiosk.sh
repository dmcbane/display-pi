#!/bin/bash
#
# Raspberry Pi 4/5 Worship Stream Kiosk - Setup Script
#
# Sets up a Pi 4 or Pi 5 (Raspberry Pi OS Lite, Bookworm, 64-bit) as a
# lobby/overflow display that:
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
# CONFIGURATION — built-in defaults
# =============================================================================
#
# These values are the starting point. They are overridden by:
#   1. A config file (default: /etc/kiosk-setup.conf, override with --conf)
#      sourced as bash syntax, e.g.:
#          STREAM_KEY=mykey
#          RTMP_ALLOW_PUBLISH_CIDRS=(192.168.1.0/24 10.0.0.0/8)
#   2. Command-line flags (see --help)
#
# Later sources win over earlier ones.
# =============================================================================

# Network CIDRs allowed to push RTMP to this Pi. Tighten to the ATEM's IP
# (e.g. "192.168.1.42/32") once you know it's stable.
RTMP_ALLOW_PUBLISH_CIDRS=("192.168.0.0/16" "10.0.0.0/8")

# The stream key the ATEM will push with. Must match ATEM's config.
STREAM_KEY="church242"

# The RTMP application name (the path component before the key).
RTMP_APP="live"

# Splash image text (used to generate a placeholder PNG).
# Replace /home/kiosk/splash.png with your branded image after setup.
SPLASH_TEXT="Service will begin shortly"

# Kiosk user. Created if missing. Do not change after first run.
KIOSK_USER="kiosk"

# mpv volume for the lobby/overflow display (0-100).
PLAYBACK_VOLUME=80

# Config file path. Override with --conf /path/to/file.
CONF_FILE="/etc/kiosk-setup.conf"

# =============================================================================
# Below this line you shouldn't need to edit.
# =============================================================================

readonly STAMP=$(date +%Y%m%d-%H%M%S)
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [OPTIONS]

Configure a Raspberry Pi kiosk that receives an RTMP stream and plays it
fullscreen under cage. Idempotent: safe to re-run.

Configuration is layered (later sources override earlier):
  1. Built-in defaults
  2. Config file (bash syntax, sourced if present)
  3. Command-line options below

Options:
  --stream-key KEY     RTMP stream key the publisher will push with.
                       Default: $STREAM_KEY
  --rtmp-app NAME      RTMP application name (path component before the key).
                       Default: $RTMP_APP
  --allow-cidr CIDR    Allow RTMP publish from this CIDR. Repeatable; the
                       first use clears the defaults, subsequent uses append.
                       Defaults: ${RTMP_ALLOW_PUBLISH_CIDRS[*]}
  --kiosk-user USER    Unix account for the kiosk. Created if missing.
                       Default: $KIOSK_USER
  --volume N           mpv playback volume, 0-100.
                       Default: $PLAYBACK_VOLUME
  --splash-text TEXT   Caption burned into the placeholder splash image.
                       Default: "$SPLASH_TEXT"
  --conf PATH          Config file path (sourced as bash if it exists).
                       Default: $CONF_FILE
  -h, --help           Show this help and exit.

Config file example:
    STREAM_KEY=mykey
    RTMP_APP=live
    RTMP_ALLOW_PUBLISH_CIDRS=(192.168.1.0/24 10.0.0.0/8)
    KIOSK_USER=kiosk
    PLAYBACK_VOLUME=75
    SPLASH_TEXT="Be right back"
USAGE
}

# Two-pass CLI parsing: we need to know --conf before we source it so the
# config file can be loaded before the rest of the flags override it.
# Pass 1 extracts only --conf and --help; pass 2 applies everything.
parse_conf_path() {
    local args=("$@")
    local i=0
    while (( i < ${#args[@]} )); do
        case "${args[i]}" in
            -h|--help) usage; exit 0 ;;
            --conf)    CONF_FILE="${args[i+1]:?--conf requires a path}"; i+=2 ;;
            --conf=*)  CONF_FILE="${args[i]#*=}"; i+=1 ;;
            *)         i+=1 ;;
        esac
    done
}

load_conf_file() {
    if [[ -f "$CONF_FILE" ]]; then
        log "Loading config from $CONF_FILE"
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi
}

parse_args() {
    local cidrs_reset=0
    while (( $# > 0 )); do
        case "$1" in
            --stream-key)    STREAM_KEY="${2:?--stream-key requires a value}"; shift 2 ;;
            --stream-key=*)  STREAM_KEY="${1#*=}"; shift ;;
            --rtmp-app)      RTMP_APP="${2:?--rtmp-app requires a value}"; shift 2 ;;
            --rtmp-app=*)    RTMP_APP="${1#*=}"; shift ;;
            --allow-cidr)
                (( cidrs_reset )) || { RTMP_ALLOW_PUBLISH_CIDRS=(); cidrs_reset=1; }
                RTMP_ALLOW_PUBLISH_CIDRS+=("${2:?--allow-cidr requires a value}")
                shift 2
                ;;
            --allow-cidr=*)
                (( cidrs_reset )) || { RTMP_ALLOW_PUBLISH_CIDRS=(); cidrs_reset=1; }
                RTMP_ALLOW_PUBLISH_CIDRS+=("${1#*=}")
                shift
                ;;
            --kiosk-user)    KIOSK_USER="${2:?--kiosk-user requires a value}"; shift 2 ;;
            --kiosk-user=*)  KIOSK_USER="${1#*=}"; shift ;;
            --volume)        PLAYBACK_VOLUME="${2:?--volume requires a value}"; shift 2 ;;
            --volume=*)      PLAYBACK_VOLUME="${1#*=}"; shift ;;
            --splash-text)   SPLASH_TEXT="${2:?--splash-text requires a value}"; shift 2 ;;
            --splash-text=*) SPLASH_TEXT="${1#*=}"; shift ;;
            --conf)          shift 2 ;;  # already handled in parse_conf_path
            --conf=*)        shift ;;
            -h|--help)       usage; exit 0 ;;
            *) die "Unknown option: $1 (try --help)" ;;
        esac
    done
}

validate_config() {
    [[ -n "$STREAM_KEY" ]] || die "STREAM_KEY must not be empty"
    [[ -n "$RTMP_APP"   ]] || die "RTMP_APP must not be empty"
    [[ -n "$KIOSK_USER" ]] || die "KIOSK_USER must not be empty"
    [[ "$KIOSK_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || die "KIOSK_USER '$KIOSK_USER' is not a valid Unix username"
    [[ "$PLAYBACK_VOLUME" =~ ^[0-9]+$ ]] && (( PLAYBACK_VOLUME >= 0 && PLAYBACK_VOLUME <= 100 )) \
        || die "PLAYBACK_VOLUME must be an integer 0-100 (got: $PLAYBACK_VOLUME)"
    (( ${#RTMP_ALLOW_PUBLISH_CIDRS[@]} > 0 )) \
        || die "At least one --allow-cidr is required"
}

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
#
# Copies the canonical install/nginx.conf into /etc/nginx/nginx.conf, then
# sed-patches two things that differ from repo defaults:
#   - the RTMP application name (hardcoded "live" in the file)
#   - the allow-publish CIDR list (hardcoded 192.168.0.0/16 + 10.0.0.0/8)
# =============================================================================
configure_nginx_rtmp() {
    local src="${SCRIPT_DIR}/nginx.conf"
    [[ -f "$src" ]] || die "nginx.conf not found at $src"

    log "Configuring nginx RTMP..."
    backup_once /etc/nginx/nginx.conf
    sudo cp "$src" /etc/nginx/nginx.conf

    # Patch the application name if the user configured a different one.
    if [[ "$RTMP_APP" != "live" ]]; then
        sudo sed -i "s/^        application live {/        application ${RTMP_APP} {/" \
            /etc/nginx/nginx.conf
    fi

    # Rewrite the allow-publish list: delete all existing entries, then insert
    # the configured ones immediately before `deny publish all;`.
    sudo sed -i '/^            allow publish /d' /etc/nginx/nginx.conf
    local sed_allow=""
    for cidr in "${RTMP_ALLOW_PUBLISH_CIDRS[@]}"; do
        sed_allow+="            allow publish ${cidr};\n"
    done
    sudo sed -i "s|^            deny publish all;|${sed_allow}            deny publish all;|" \
        /etc/nginx/nginx.conf

    sudo nginx -t || die "nginx config test failed. Check /etc/nginx/nginx.conf"
    sudo systemctl enable nginx
    sudo systemctl restart nginx
    log "nginx RTMP listening on :1935 (app=${RTMP_APP}, key=${STREAM_KEY})"
}

# =============================================================================
# Step 5: Boot config  (KMS-correct, minimal, Bookworm-safe, Pi 4/5)
# =============================================================================
#
# Bookworm uses the KMS graphics driver. Legacy firmware directives like
# disable_overscan and gpu_mem are ignored under KMS. For hotplug:
#
#   - Pi 4: hdmi_force_hotplug in config.txt can wedge the firmware boot
#           stage (rainbow screen hang) under KMS. We instead set
#           vc4.force_hotplug=1 in cmdline.txt — the vc4-kms-v3d driver
#           reads it and the firmware never sees it.
#
#   - Pi 5: the vc4.force_hotplug cmdline param is silently ignored
#           (different KMS pipeline). The supported replacement is
#           hdmi_force_hotplug:0=1 in config.txt, scoped to HDMI-0 via
#           the `:0` suffix. We put it under a [pi5] filter so it
#           applies to Pi 5 only.
#
# Universal (both models):
#   - consoleblank=0        cmdline.txt — prevents framebuffer console
#                           from blanking before cage+mpv take over.
#   - dtparam=watchdog=on   config.txt — enables the hardware watchdog.
#   - dtoverlay=disable-bt  config.txt — frees the primary UART; kiosk
#                           doesn't need Bluetooth.
#
# Additions are wrapped in marker comments so the script can remove
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
# Hardware watchdog for auto-recovery from kernel hangs (Pi 4 and Pi 5)
dtparam=watchdog=on
# Free the UART and save a little power; kiosk doesn't use Bluetooth
dtoverlay=disable-bt

# Pi 5 only: force HDMI-0 hotplug so a TV powered off at boot doesn't
# leave the Pi with no display modes. (Pi 4 handles this via
# vc4.force_hotplug=1 in cmdline.txt — see below.)
[pi5]
hdmi_force_hotplug:0=1
[all]
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
#
# Copies the canonical install/player.sh into the kiosk user's ~/bin, then
# sed-patches the three configurable assignment lines near the top of the
# file so setup can be re-run with different STREAM_KEY/RTMP_APP/VOLUME/
# KIOSK_USER values without editing the source file.
# =============================================================================
create_player_script() {
    local src="${SCRIPT_DIR}/player.sh"
    [[ -f "$src" ]] || die "player.sh not found at $src"

    local player_dir="/home/${KIOSK_USER}/bin"
    local player_script="${player_dir}/player.sh"
    local stream_url="rtmp://127.0.0.1/${RTMP_APP}/${STREAM_KEY}"

    log "Installing player script to $player_script ..."
    sudo -u "$KIOSK_USER" mkdir -p "$player_dir"
    sudo cp "$src" "$player_script"
    sudo chown "$KIOSK_USER:$KIOSK_USER" "$player_script"
    sudo chmod +x "$player_script"

    sudo sed -i \
        -e "s|^STREAM_URL=.*|STREAM_URL=\"${stream_url}\"|" \
        -e "s|^SPLASH_IMAGE=.*|SPLASH_IMAGE=\"/home/${KIOSK_USER}/splash.png\"|" \
        -e "s|^VOLUME=.*|VOLUME=${PLAYBACK_VOLUME}|" \
        "$player_script"

    log "Player script installed."
}

# =============================================================================
# Step 8: systemd user service
# =============================================================================
#
# Copies the canonical install/kiosk.service into the kiosk user's
# ~/.config/systemd/user/, sed-patching the ExecStart path only if
# KIOSK_USER was changed from the default ("kiosk").
# =============================================================================
install_kiosk_service() {
    local src="${SCRIPT_DIR}/kiosk.service"
    [[ -f "$src" ]] || die "kiosk.service not found at $src"

    local service_dir="/home/${KIOSK_USER}/.config/systemd/user"
    local service_file="${service_dir}/kiosk.service"

    log "Installing systemd user service..."
    sudo -u "$KIOSK_USER" mkdir -p "$service_dir"
    sudo cp "$src" "$service_file"
    sudo chown "$KIOSK_USER:$KIOSK_USER" "$service_file"

    if [[ "$KIOSK_USER" != "kiosk" ]]; then
        sudo sed -i "s|/home/kiosk/|/home/${KIOSK_USER}/|g" "$service_file"
    fi

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

    # Ensure pipewire + wireplumber user services are enabled for the kiosk
    # user so they start automatically alongside the lingering systemd user
    # session. mpv's audio output (--audio-device=auto) requires pipewire to
    # be running, and the default socket-activation sometimes doesn't fire
    # from a headless kiosk session.
    local kiosk_uid
    kiosk_uid=$(id -u "$KIOSK_USER")
    sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/${kiosk_uid}" \
        systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || \
        warn "Could not enable pipewire user services (will try on next reboot)."
}

# =============================================================================
# Step 11: Log rotation for /tmp/player.log
# =============================================================================
configure_logrotate() {
    local src="${SCRIPT_DIR}/logrotate-kiosk"
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
    local src="${SCRIPT_DIR}/healthcheck.sh"
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
    parse_conf_path "$@"
    load_conf_file
    parse_args "$@"
    validate_config

    require_root_capable
    confirm_os

    log "Starting kiosk setup (backup suffix: .bak-${STAMP})"
    log "  stream:     rtmp://<pi>/${RTMP_APP}/${STREAM_KEY}"
    log "  allow cidr: ${RTMP_ALLOW_PUBLISH_CIDRS[*]}"
    log "  kiosk user: ${KIOSK_USER}"
    log "  volume:     ${PLAYBACK_VOLUME}"

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

Pi 5 notes:
  - Pi 5 has no hardware H.264 decoder; playback is software-decoded
    on the A76 cores. 1080p30 is comfortable (~30% of one core); for
    1080p60 budget ~50%. 4Kp30 H.264 is not recommended.
  - Use the official 27 W (5V/5A) USB-C PSU. A 3 A supply boots but
    throttles USB to 600 mA and limits HAT power.
  - Active cooling is required under sustained software decode. Use
    the official Active Cooler or an equivalent case-with-fan; without
    one, expect thermal throttling around 85 °C.

EOF
}

main "$@"
