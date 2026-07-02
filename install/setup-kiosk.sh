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
STREAM_KEY="${STREAM_KEY:-restoration}"

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

# HDMI mode to force at boot. Under Bookworm KMS the legacy firmware
# knobs (hdmi_group, hdmi_mode, hdmi_drive) in config.txt are silently
# ignored — the working knob is the kernel `video=` parameter in
# cmdline.txt, and this script owns it.
#
# Format: "<width>x<height>@<refresh>", e.g. "1920x1080@30".
# Special value "none" removes any prior video=HDMI-A-1: token.
# Unset / empty leaves cmdline.txt untouched (lets EDID pick).
#
# Re-running setup with a different HDMI_MODE rewrites the token
# idempotently. Use dev/set-hdmi-mode.sh (or `make hdmi-mode`) to
# apply this to an already-deployed Pi without re-running full setup.
HDMI_MODE="${HDMI_MODE:-}"

# Extra static IPv4 address to bind to the Ethernet adapter *in addition* to
# DHCP, so the Pi stays reachable at a fixed address on networks with no DHCP
# server — a laptop patched straight into the Pi, a dumb switch, a temporary
# field rig. NetworkManager still requests a DHCP lease, so this never breaks
# normal LAN use; it just adds a second address on the same NIC.
#
# Format: "<addr>/<prefix>", e.g. "192.168.50.1/24". Point the connecting
# machine at another address in the same subnet (192.168.50.2/24) and reach
# the Pi at 192.168.50.1.
#
# Unset / empty leaves addressing to DHCP only. Special value "none" removes
# a static IP added by a previous run and returns the link to DHCP-only.
STATIC_IP="${STATIC_IP:-}"

# System-wide default locale for the Pi. A fresh Raspberry Pi OS Lite image
# generates almost no locales, so any SSH client that forwards LANG/LC_* (the
# default on macOS and most desktops) produces "cannot change locale" warnings
# at every login. configure_locale generates this locale, makes it the default,
# and stops sshd from importing the client's forwarded values — so the result
# is clean and identical no matter where someone logs in from. Match your
# region if not US English (e.g. "en_GB.UTF-8").
DISPLAY_LOCALE="${DISPLAY_LOCALE:-en_US.UTF-8}"

# Optional public key to install for passwordless SSH, given as the key
# *content* (e.g. "ssh-ed25519 AAAA... you@host"), not a path — setup runs on
# the Pi, where the workstation's key file isn't present. `make setup
# SSH_PUBKEY=~/.ssh/id_ed25519.pub` reads that file and forwards its contents
# here. Empty = skip (the default). Passwordless SSH stays opt-in; run
# `make ssh-copy-key` later to add a key without re-running setup.
SSH_PUBKEY="${SSH_PUBKEY:-}"

# =============================================================================
# Below this line you shouldn't need to edit.
# =============================================================================

readonly STAMP=$(date +%Y%m%d-%H%M%S)
readonly SCRIPT_NAME=$(basename "$0")

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

# Back up a file before modifying. Two skips:
#   1. Already backed up in THIS run (same STAMP) — repeat callers are free.
#   2. The most recent existing backup is byte-identical to the live file.
#      Idempotent re-runs of setup-kiosk.sh were piling up timestamped
#      copies of files that hadn't changed (19 accumulated across 3 re-runs
#      on 2026-06-13). Skipping in this case keeps the audit trail meaningful
#      — a new .bak-${STAMP} now reliably means "the file actually changed".
backup_once() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    [[ -f "${file}.bak-${STAMP}" ]] && return 0

    # `ls` returns non-zero when the glob has no matches; under set -euo
    # pipefail that would kill the script, so allow an empty result.
    local latest
    latest=$(sudo ls -1t "${file}".bak-* 2>/dev/null | head -1 || true)
    if [[ -n "$latest" ]] && sudo cmp -s "$file" "$latest"; then
        return 0
    fi

    sudo cp -a "$file" "${file}.bak-${STAMP}"
    log "Backed up $file -> ${file}.bak-${STAMP}"
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
    if ! grep -qE 'bookworm|trixie' /etc/os-release 2>/dev/null; then
        warn "Not Bookworm or Trixie. Paths like /boot/firmware may differ."
    fi
}

# =============================================================================
# Step 1: Packages
# =============================================================================
install_packages() {
    log "Updating apt and installing packages..."
    sudo apt-get update

    # vcgencmd ships in different packages across Pi OS releases:
    #   Pi OS 12 (Bookworm): libraspberrypi-bin
    #   Pi OS 13 (Trixie):   raspi-utils  (libraspberrypi-bin is gone)
    # Pick whichever apt knows about. raspi-utils first since Trixie is current.
    local vcgencmd_pkg
    if apt-cache show raspi-utils >/dev/null 2>&1; then
        vcgencmd_pkg=raspi-utils
    elif apt-cache show libraspberrypi-bin >/dev/null 2>&1; then
        vcgencmd_pkg=libraspberrypi-bin
    else
        die "Neither raspi-utils nor libraspberrypi-bin available — vcgencmd has no source."
    fi
    log "vcgencmd provider: $vcgencmd_pkg"

    # Display + media stack
    #   cage / mpv / seatd        — kiosk compositor + player + seat manager
    #   nginx + libnginx-mod-rtmp — RTMP ingest from the ATEM
    #   ffmpeg                    — provides ffprobe (stream liveness check)
    #   imagemagick               — render-status.sh diagnostic PNGs
    #   pipewire / wireplumber    — audio stack (mpv pins to ALSA, but
    #                               assess.sh probes PipeWire sinks)
    #   watchdog / cec-utils      — auto-recovery + HDMI-CEC TV control
    # Operations + diagnostics tools used across install/ and diagnostics/
    #   netcat-openbsd            — `nc` for nginx readiness gate (player.sh,
    #                               healthcheck.sh, assess.sh, render-status.sh).
    #                               Kiosk hangs at boot without it.
    #   wlr-randr                 — judder.sh: read the active Wayland mode
    #   libdrm-tests              — provides kmsprint (KMS connector dump)
    #   $vcgencmd_pkg             — provides vcgencmd (thermal/throttle readout);
    #                               raspi-utils on Trixie, libraspberrypi-bin on Bookworm
    #   alsa-utils                — provides aplay (audio fallback probe)
    #   systemd-container         — provides machinectl, referenced in the
    #                               post-install instructions for inspecting
    #                               the kiosk user's --user systemd units
    #   python3-defusedxml        — diagnostics/parse_stat.py prefers it over
    #                               stdlib ET for XXE/billion-laughs hardening
    sudo apt-get install -y --no-install-recommends \
        cage mpv seatd \
        libnginx-mod-rtmp nginx \
        watchdog cec-utils \
        ffmpeg imagemagick fonts-dejavu-core \
        ca-certificates curl logrotate cron \
        pipewire pipewire-audio wireplumber \
        netcat-openbsd \
        wlr-randr libdrm-tests "$vcgencmd_pkg" alsa-utils \
        systemd-container \
        python3-defusedxml
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

    # Ensure required group memberships (idempotent). seatd does not need
    # a POSIX 'seat' group — libseat auth happens over a Unix socket.
    for group in video render input audio; do
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

    # rtmp_stat — XML dump of active publishers/streams. Localhost-only.
    # Lets diagnostics/judder.sh probe surface the real stream key when a
    # publisher is connected to nginx but not to the key the player expects.
    server {
        listen 127.0.0.1:8080;
        server_name localhost;

        location /stat {
            rtmp_stat all;
            allow 127.0.0.1;
            deny all;
        }
    }
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

    # Strip any stale video=HDMI-A-1:* token. Pi 5 / Trixie regression
    # 2026-06-13: a kernel `video=` parameter synthesizes a modeline that
    # diverges from EDID-reported modes, leaving KMS at the synthesized
    # mode and wayland (cage) at the EDID-preferred mode. The mismatch
    # makes every atomic commit fail with "Invalid argument" — black
    # screen. The single source of truth for HDMI mode is now HDMI_MODE
    # in /etc/default/kiosk, applied at runtime by player.sh via
    # wlr-randr. setup-kiosk.sh and dev/set-hdmi-mode.sh always strip
    # the cmdline.txt token and never add one.
    local new="$current"
    local hdmi_changed=0
    local stripped
    stripped=$(printf '%s' "$new" | sed -E 's/( |^)video=HDMI-A-1:[^ ]+//g; s/  +/ /g; s/^ //; s/ $//')
    if [[ "$stripped" != "$new" ]]; then
        log "Stripping stale video=HDMI-A-1: from cmdline.txt (HDMI_MODE owns this now)"
        new="$stripped"
        hdmi_changed=1
    fi

    if (( ${#tokens_to_add[@]} > 0 )); then
        new="${new} ${tokens_to_add[*]}"
        log "Added to cmdline.txt: ${tokens_to_add[*]}"
    fi

    if (( ${#tokens_to_add[@]} > 0 )) || (( hdmi_changed )); then
        # Normalize whitespace before writing
        new=$(echo "$new" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
        echo "$new" | sudo tee "$cmdline_file" > /dev/null
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

# Runtime mode-enforcement layer: write /etc/default/kiosk so kiosk.service
# (via EnvironmentFile=-) and player.sh (force_display_mode) can run
# `wlr-randr --output $HDMI_OUTPUT --mode $HDMI_MODE` inside the cage
# session. This is the authoritative layer; the kernel `video=` cmdline
# parameter is only a boot-time hint.
install_become_kiosk() {
    # Install the become-kiosk helper to /usr/local/bin so the deploy user
    # (or any SSH user with sudo) can drop into the kiosk user's shell with
    # XDG_RUNTIME_DIR set, without needing to remember the long sudo
    # incantation. The source lives in install/ so it ships with the repo;
    # we copy (not symlink) so a stale checkout can't break the helper.
    local src dst
    src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/become-kiosk.sh"
    dst="/usr/local/bin/become-kiosk"

    if [[ ! -f "$src" ]]; then
        warn "become-kiosk.sh not found at $src; skipping helper install."
        return
    fi

    log "Installing $dst from $src..."
    sudo install -m 0755 -o root -g root "$src" "$dst"
}

configure_runtime_mode() {
    local env_file=/etc/default/kiosk
    local marker_start="# === kiosk-setup BEGIN ==="
    local marker_end="# === kiosk-setup END ==="

    if [[ -z "$HDMI_MODE" ]]; then
        log "HDMI_MODE unset; leaving $env_file alone (EDID picks mode)."
        return
    fi

    log "Writing $env_file (HDMI_MODE=${HDMI_MODE})..."
    if [[ -f "$env_file" ]]; then
        backup_once "$env_file"
        # Strip any prior kiosk-setup block (idempotent re-runs).
        sudo sed -i "/${marker_start}/,/${marker_end}/d" "$env_file"
    fi

    if [[ "$HDMI_MODE" == "none" ]]; then
        log "HDMI_MODE=none — clearing HDMI_MODE."
        sudo tee -a "$env_file" > /dev/null <<EOF
${marker_start}
# Runtime HDMI mode enforcement (cleared by setup-kiosk.sh on ${STAMP}).
# Leave HDMI_MODE empty to let EDID pick the active mode.
HDMI_MODE=
HDMI_OUTPUT=HDMI-A-1
${marker_end}
EOF
    else
        sudo tee -a "$env_file" > /dev/null <<EOF
${marker_start}
# Runtime HDMI mode enforcement (written by setup-kiosk.sh on ${STAMP}).
# Consumed by kiosk.service (EnvironmentFile=) and player.sh
# (force_display_mode runs wlr-randr before mpv). Change with
# \`make hdmi-mode HDMI_MODE=…\` so both this file and cmdline.txt
# stay in sync.
HDMI_MODE=${HDMI_MODE}
HDMI_OUTPUT=HDMI-A-1
${marker_end}
EOF
    fi
    sudo chmod 644 "$env_file"
}

# =============================================================================
# Optional: extra static IP on the Ethernet adapter (alongside DHCP)
# =============================================================================
# Owns a dedicated NetworkManager profile named "kiosk-static" that does DHCP
# *and* binds an extra fixed IPv4 address, so the Pi is reachable at a known
# address even when no DHCP server is present. The profile is recreated from
# scratch on every run (idempotent — re-runs never stack duplicate addresses)
# and is given a higher autoconnect priority so it wins over the stock
# "Wired connection 1" on the next boot.
#
# We deliberately do NOT reactivate the link here: `make setup` runs over SSH
# on that same NIC, and bouncing the connection would drop the session
# mid-setup. The DHCP address is untouched, so the change lands cleanly on the
# reboot setup already asks for.
configure_static_ip() {
    local profile="kiosk-static"

    if ! command -v nmcli >/dev/null 2>&1; then
        if [[ -n "$STATIC_IP" ]]; then
            warn "nmcli not found (NetworkManager not active?); cannot apply STATIC_IP='$STATIC_IP'. Skipping."
        fi
        return
    fi

    # Special value "none" tears down a previously-added static IP.
    if [[ "$STATIC_IP" == "none" ]]; then
        if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$profile"; then
            log "STATIC_IP=none — removing '$profile' NetworkManager profile (DHCP-only on next boot)."
            sudo nmcli connection delete "$profile" >/dev/null
        else
            log "STATIC_IP=none — no '$profile' profile present; nothing to remove."
        fi
        return
    fi

    if [[ -z "$STATIC_IP" ]]; then
        log "STATIC_IP unset; leaving Ethernet addressing to DHCP only."
        return
    fi

    # Validate <ipv4>/<prefix> before touching NetworkManager.
    if ! [[ "$STATIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        die "STATIC_IP must be <ipv4>/<prefix> (e.g. 192.168.50.1/24); got '$STATIC_IP'."
    fi

    # Detect the ethernet device (the Pi keeps eth0, but detect to be safe).
    local dev
    dev=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="ethernet"{print $1; exit}')
    dev="${dev:-eth0}"

    log "Configuring extra static IP $STATIC_IP on $dev via '$profile' (applies on next reboot)."

    # Recreate from scratch so re-runs are idempotent and never accumulate
    # stale addresses. method=auto keeps DHCP; ipv4.addresses adds the fixed
    # address on top. No gateway/DNS — this is a direct-reach address, not the
    # default route.
    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$profile"; then
        sudo nmcli connection delete "$profile" >/dev/null
    fi
    sudo nmcli connection add type ethernet \
        con-name "$profile" ifname "$dev" \
        ipv4.method auto ipv4.addresses "$STATIC_IP" \
        connection.autoconnect yes connection.autoconnect-priority 100 \
        >/dev/null
    log "Created '$profile' (DHCP + static $STATIC_IP). Reboot to activate."
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

    # images/ lives one level up from this script (repo root). Resolve it
    # via the script's own path so setup works regardless of CWD.
    local images_dir
    images_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../images"

    # Preference 1: a ready-made images/splash.png ships with the repo.
    if [[ -f "${images_dir}/splash.png" ]]; then
        log "Installing splash image from ${images_dir}/splash.png ..."
        # images_dir lives under the SSH user's 0700 home (display-pi-bootstrap),
        # so `sudo -u kiosk cp` can't traverse in to read it. Copy as root via
        # install(1); -o/-g hand the destination to the kiosk user atomically.
        sudo install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 0644 \
            "${images_dir}/splash.png" "$splash_path"
        log "Splash installed at $splash_path."
        return
    fi

    # Preference 2: no splash.png, but other images exist — ask which to use.
    local candidates=()
    if [[ -d "$images_dir" ]]; then
        while IFS= read -r -d '' img; do
            candidates+=("$img")
        done < <(find "$images_dir" -maxdepth 1 -type f \
            \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0 \
            2>/dev/null | sort -z)
    fi
    # Only prompt on a real terminal; a non-interactive run falls through to
    # the generated placeholder rather than hanging on EOF.
    if [[ ${#candidates[@]} -gt 0 && -t 0 ]]; then
        log "No ${images_dir}/splash.png found, but ${#candidates[@]} other image(s) are available."
        local choice
        PS3="Select a splash image to install: "
        select choice in "${candidates[@]}"; do
            if [[ -n "$choice" ]]; then
                log "Installing splash image from $choice ..."
                # Copy as root (see note above) — the chosen image is under the
                # SSH user's 0700 home, unreadable to the kiosk user.
                sudo install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 0644 \
                    "$choice" "$splash_path"
                log "Splash installed at $splash_path."
                return
            fi
            echo "Invalid selection — enter a number from the list."
        done
    fi

    # Preference 3: nothing usable in images/ — generate a placeholder.
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
# Rotation folder (cycled one image per splash entry) + legacy single-image
# fallback. Overridable via /etc/default/kiosk.
SPLASH_DIR="\${SPLASH_DIR:-/home/${KIOSK_USER}/splash.d}"
SPLASH_IMAGE="\${SPLASH_IMAGE:-/home/${KIOSK_USER}/splash.png}"
SPLASH_STATE="\${SPLASH_STATE:-/home/${KIOSK_USER}/.splash-index}"
VOLUME=${PLAYBACK_VOLUME}

# Pick the next splash image and advance the cursor. Runs in the parent shell
# (the \$(show_splash) subshell can't carry the cursor); returns the path via
# SPLASH_NEXT. Re-reads the folder each call; non-zero when nothing is usable.
next_splash_image() {
    local images=()
    if [[ -d "\$SPLASH_DIR" ]]; then
        while IFS= read -r -d '' f; do
            images+=("\$f")
        done < <(find -L "\$SPLASH_DIR" -maxdepth 1 -type f \\
            \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \\) -print0 \\
            2>/dev/null | sort -z)
    fi
    if (( \${#images[@]} == 0 )); then
        if [[ -f "\$SPLASH_IMAGE" ]]; then
            SPLASH_NEXT="\$SPLASH_IMAGE"
            return 0
        fi
        return 1
    fi
    local idx=0
    if [[ -r "\$SPLASH_STATE" ]]; then
        idx=\$(< "\$SPLASH_STATE")
        [[ "\$idx" =~ ^[0-9]+\$ ]] || idx=0
    fi
    SPLASH_NEXT="\${images[idx % \${#images[@]}]}"
    echo \$(( (idx + 1) % \${#images[@]} )) > "\$SPLASH_STATE" 2>/dev/null || true
    return 0
}

show_splash() {
    # \$1 is the image to show. Redirect mpv off the \$(...) pipe so the
    # command substitution that captures the PID doesn't block on EOF.
    mpv --fullscreen --really-quiet --loop \\
        --image-display-duration=inf \\
        --no-input-default-bindings \\
        --no-audio \\
        "\$1" </dev/null >/dev/null 2>&1 &
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
        if next_splash_image; then
            SPLASH_PID=\$(show_splash "\$SPLASH_NEXT")
        else
            echo "ERROR: no splash image in \$SPLASH_DIR or \$SPLASH_IMAGE" >&2
            SPLASH_PID=""
        fi
        while ! stream_live; do
            sleep 3
        done
        if [[ -n "\$SPLASH_PID" ]]; then
            kill "\$SPLASH_PID" 2>/dev/null || true
            wait "\$SPLASH_PID" 2>/dev/null || true
        fi
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
    # See docs/dev-journal/2026-04-25-hdmi-audio-routing.md.
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
# sudo entirely. See docs/dev-journal/2026-04-25-hdmi-audio-routing.md.
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
# Step 10c: SSH auth — allow login by public key OR password
# =============================================================================
#
# Delegates to `install/sshd-password-toggle.sh on`, which writes the
# /etc/ssh/sshd_config.d/00-display-pi-auth.conf drop-in (pubkey always on,
# password on), validates with `sshd -t`, and reloads sshd. Flip password
# auth off later with `sudo bash install/sshd-password-toggle.sh off` or, from
# the workstation, `make ssh-password STATE=off`.
configure_ssh_auth() {
    local src
    src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sshd-password-toggle.sh"

    if [[ ! -f "$src" ]]; then
        warn "sshd-password-toggle.sh not found at $src; skipping SSH auth config."
        return
    fi

    log "Enabling SSH login by public key OR password..."
    sudo bash "$src" on
}

# =============================================================================
# Step 10d: Locale — a clean login from anywhere, no forwarded-locale warnings
# =============================================================================
#
# Two independent things make the "cannot change locale" warning appear at
# login: (1) the target locale isn't generated on the Pi, and (2) sshd imports
# the LANG/LC_* the client forwards. We fix both so the outcome is the same no
# matter which machine someone connects from:
#
#   1. Generate DISPLAY_LOCALE and set it as the system-wide default LANG.
#   2. Strip LANG/LC_* from sshd's AcceptEnv so forwarded values are ignored
#      entirely — the session always uses the Pi's own default.
#
# Idempotent: an already-generated locale and an already-stripped AcceptEnv are
# left untouched on re-run.
configure_locale() {
    log "Configuring system locale '$DISPLAY_LOCALE' and neutralizing forwarded SSH locales..."

    # 1. Uncomment the locale in /etc/locale.gen (the '.' stays a regex dot —
    #    harmless), then generate it. locale-gen is a cheap no-op if current.
    if grep -qE "^# *${DISPLAY_LOCALE} " /etc/locale.gen; then
        sudo sed -i "s/^# *\(${DISPLAY_LOCALE} \)/\1/" /etc/locale.gen
    fi
    sudo locale-gen

    # 2. Make it the system-wide default. Set LANG only (not LC_ALL) so it stays
    #    overridable; step 3 is what keeps forwarded values out of the session.
    sudo update-locale LANG="$DISPLAY_LOCALE"

    # 3. Stop sshd from importing the client's forwarded LANG/LC_*. AcceptEnv is
    #    additive and can't be subtracted from a drop-in, so edit the main config
    #    in place: drop the LANG and LC_* tokens, preserve any others (COLORTERM,
    #    NO_COLOR, ...), and comment the directive out if that empties it. Edit a
    #    temp copy and validate with `sshd -t -f` before installing, so a bad
    #    edit can never leave sshd unable to start.
    local sshd=/etc/ssh/sshd_config
    if grep -qE '^[[:space:]]*AcceptEnv[[:space:]].*(LANG|LC_)' "$sshd"; then
        backup_once "$sshd"
        local tmp
        tmp=$(mktemp)
        trap "rm -f '$tmp'" RETURN
        sudo sed -E "/^[[:space:]]*AcceptEnv/{
            s/[[:space:]]+LANG( |\$)/ /g
            s/[[:space:]]+LC_\*( |\$)/ /g
            s/[[:space:]]+\$//
            s/^([[:space:]]*)AcceptEnv[[:space:]]*\$/\1#AcceptEnv (locale forwarding disabled by display-pi)/
        }" "$sshd" > "$tmp"

        if sudo sshd -t -f "$tmp"; then
            sudo install -o root -g root -m 0644 "$tmp" "$sshd"
            sudo systemctl reload ssh
            log "sshd no longer imports forwarded LANG/LC_*; logins use $DISPLAY_LOCALE."
        else
            die "sshd -t rejected the edited config; left $sshd unchanged."
        fi
    else
        log "sshd AcceptEnv already free of LANG/LC_*; nothing to change."
    fi
}

# =============================================================================
# Step 10e: Optional passwordless-SSH key for the deploy user
# =============================================================================
#
# If SSH_PUBKEY holds a public key, install it into the deploy user's
# authorized_keys so future logins need no password. Opt-in and non-fatal: a
# missing or malformed key is warned about and skipped rather than aborting
# setup (the same key can be added later with `make ssh-copy-key`). Mirrors
# dev/ssh-copy-key.sh, but runs locally on the Pi during setup.
configure_ssh_pubkey() {
    if [[ -z "$SSH_PUBKEY" ]]; then
        log "No SSH_PUBKEY provided; skipping passwordless-SSH key install."
        return
    fi

    # Safety rail: must be a PUBLIC key line, never a private key.
    if [[ ! "$SSH_PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-) ]]; then
        warn "SSH_PUBKEY does not look like an SSH public key (expected e.g. ssh-ed25519); skipping."
        return
    fi

    local home ssh_dir auth
    home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
    if [[ -z "$home" || ! -d "$home" ]]; then
        warn "Could not resolve a home directory for '$DEPLOY_USER'; skipping SSH key install."
        return
    fi
    ssh_dir="$home/.ssh"
    auth="$ssh_dir/authorized_keys"

    log "Installing SSH public key for passwordless login as '$DEPLOY_USER'..."
    sudo -u "$DEPLOY_USER" mkdir -p "$ssh_dir"
    sudo -u "$DEPLOY_USER" chmod 700 "$ssh_dir"
    sudo -u "$DEPLOY_USER" touch "$auth"
    sudo -u "$DEPLOY_USER" chmod 600 "$auth"

    # Idempotent: append only if the exact key line isn't already present.
    if sudo -u "$DEPLOY_USER" grep -qxF "$SSH_PUBKEY" "$auth"; then
        log "Key already present in $auth; nothing to do."
    else
        printf '%s\n' "$SSH_PUBKEY" | sudo -u "$DEPLOY_USER" tee -a "$auth" >/dev/null
        log "Key added to $auth — '$DEPLOY_USER' can now SSH without a password."
    fi
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
    configure_runtime_mode
    configure_static_ip
    install_become_kiosk
    create_splash
    create_player_script
    install_kiosk_service
    configure_watchdog
    configure_pipewire
    configure_deploy_sudoers
    configure_ssh_auth
    configure_locale
    configure_ssh_pubkey
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

        # Kiosk service status (uses become-kiosk helper installed below)
        become-kiosk systemctl --user status kiosk.service

        # Live player logs (system journal: kiosk is not in systemd-journal
        # group, so we read as root and filter on the user-unit name)
        sudo journalctl _SYSTEMD_USER_UNIT=kiosk.service -f

  4. Test the full stream path WITHOUT the ATEM (from another machine):
        ffmpeg -re -f lavfi -i testsrc=size=1920x1080:rate=30 \\
               -f lavfi -i sine=frequency=440 \\
               -c:v libx264 -preset veryfast -tune zerolatency \\
               -c:a aac -f flv rtmp://<PI_IP>/${RTMP_APP}/${STREAM_KEY}

Replace /home/${KIOSK_USER}/splash.png with your own branded image
whenever you like; the kiosk picks it up on the next idle period.

EOF

    if [[ -n "$STATIC_IP" && "$STATIC_IP" != "none" ]]; then
        cat <<EOF
Extra static IP: after reboot the Pi also answers at ${STATIC_IP%/*}.
On a DHCP-less network, give your machine an address in the same subnet
(e.g. ${STATIC_IP%.*}.2/${STATIC_IP##*/}) and SSH to ${STATIC_IP%/*}.

EOF
    fi
}

main "$@"
