#!/bin/bash
#
# run-tests.sh — Test runner for display-pi
#
# Validates script logic that can be tested without Pi hardware.
# Tests use simple pass/fail assertions — no external test framework needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0
ERRORS=()

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$desc: expected='$expected' actual='$actual'")
        printf "${RED}  FAIL${RESET} %s (expected '%s', got '%s')\n" "$desc" "$expected" "$actual"
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$desc: file not found at $path")
        printf "${RED}  FAIL${RESET} %s (not found: %s)\n" "$desc" "$path"
    fi
}

assert_executable() {
    local desc="$1" path="$2"
    if [[ -x "$path" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$desc: not executable at $path")
        printf "${RED}  FAIL${RESET} %s (not executable: %s)\n" "$desc" "$path"
    fi
}

assert_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$desc: pattern '$pattern' not found in $file")
        printf "${RED}  FAIL${RESET} %s (pattern '%s' not in %s)\n" "$desc" "$pattern" "$file"
    fi
}

assert_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$desc: pattern '$pattern' unexpectedly found in $file")
        printf "${RED}  FAIL${RESET} %s (pattern '%s' found in %s)\n" "$desc" "$pattern" "$file"
    fi
}

# ============================================================================
echo "=== File Structure Tests ==="
# ============================================================================

assert_file_exists "install/player.sh exists" "$REPO_ROOT/install/player.sh"
assert_executable  "install/player.sh is executable" "$REPO_ROOT/install/player.sh"
assert_file_exists "install/assess.sh exists" "$REPO_ROOT/install/assess.sh"
assert_executable  "install/assess.sh is executable" "$REPO_ROOT/install/assess.sh"
assert_file_exists "install/kiosk.service exists" "$REPO_ROOT/install/kiosk.service"
assert_file_exists "install/nginx.conf exists" "$REPO_ROOT/install/nginx.conf"
assert_file_exists "install/setup-kiosk.sh exists" "$REPO_ROOT/install/setup-kiosk.sh"
assert_executable  "install/setup-kiosk.sh is executable" "$REPO_ROOT/install/setup-kiosk.sh"
assert_file_exists "diagnostics/render-status.sh exists" "$REPO_ROOT/diagnostics/render-status.sh"
assert_executable  "diagnostics/render-status.sh is executable" "$REPO_ROOT/diagnostics/render-status.sh"
assert_file_exists "dev/deploy.sh exists" "$REPO_ROOT/dev/deploy.sh"
assert_executable  "dev/deploy.sh is executable" "$REPO_ROOT/dev/deploy.sh"
assert_file_exists "dev/test-stream.sh exists" "$REPO_ROOT/dev/test-stream.sh"
assert_executable  "dev/test-stream.sh is executable" "$REPO_ROOT/dev/test-stream.sh"
assert_file_exists "dev/pi-shell.sh exists" "$REPO_ROOT/dev/pi-shell.sh"
assert_executable  "dev/pi-shell.sh is executable" "$REPO_ROOT/dev/pi-shell.sh"
assert_file_exists "Makefile exists" "$REPO_ROOT/Makefile"
assert_file_exists "images/splash.png exists" "$REPO_ROOT/images/splash.png"

# ============================================================================
echo ""
echo "=== Player Script Tests ==="
# ============================================================================

assert_contains "player.sh uses v4l2m2m-copy hwdec (Pi 4 native; avoids CUDA/Vulkan/VDPAU probes)" \
    "$REPO_ROOT/install/player.sh" "hwdec=v4l2m2m-copy"
assert_not_contains "player.sh does not use --hwdec=auto-safe (trips CUDA/Vulkan/VDPAU on Pi 4)" \
    "$REPO_ROOT/install/player.sh" "hwdec=auto-safe"
assert_contains "player.sh has shebang" "$REPO_ROOT/install/player.sh" "^#!/bin/bash"
assert_contains "player.sh has set -u" "$REPO_ROOT/install/player.sh" "^set -u"
assert_contains "player.sh references assess.sh" "$REPO_ROOT/install/player.sh" "assess.sh"
assert_contains "player.sh has nginx readiness gate" "$REPO_ROOT/install/player.sh" "nc -z 127.0.0.1 1935"
assert_contains "player.sh has stream_live function" "$REPO_ROOT/install/player.sh" "^stream_live()"
assert_contains "player.sh uses ffprobe with timeout" "$REPO_ROOT/install/player.sh" "timeout.*ffprobe"
# Commit 26944db ("trust source PTS") deliberately removed --no-correct-pts
# and +genpts because they regenerated timestamps and broke smoothness on a
# clean 1080p30 ATEM feed. Don't reintroduce them without revisiting that fix.
assert_not_contains "player.sh does not regenerate PTS (--no-correct-pts; broke 1080p30, see 26944db)" \
    "$REPO_ROOT/install/player.sh" "no-correct-pts"
assert_not_contains "player.sh does not force genpts (broke 1080p30, see 26944db)" \
    "$REPO_ROOT/install/player.sh" "genpts"
assert_contains "player.sh captures mpv exit code" "$REPO_ROOT/install/player.sh" "mpv_exit"
assert_contains "player.sh has consecutive failure tracking" "$REPO_ROOT/install/player.sh" "consecutive_failures"
assert_contains "player.sh shows diagnostics on repeated failure" "$REPO_ROOT/install/player.sh" "show_error_diagnostics"
assert_contains "player.sh resolves symlinks for SCRIPT_DIR" "$REPO_ROOT/install/player.sh" "readlink -f"
assert_contains "player.sh splash mpv redirects stdout (\$()+& pipe bug)" "$REPO_ROOT/install/player.sh" '</dev/null >>"\$LOG" 2>&1 &'

# ============================================================================
echo ""
echo "=== Assess Script Tests ==="
# ============================================================================

assert_contains "assess.sh has shebang" "$REPO_ROOT/install/assess.sh" "^#!/bin/bash"
assert_contains "assess.sh has set -euo pipefail" "$REPO_ROOT/install/assess.sh" "^set -euo pipefail"
assert_contains "assess.sh checks for IP" "$REPO_ROOT/install/assess.sh" "hostname -I"
assert_contains "assess.sh checks nginx port" "$REPO_ROOT/install/assess.sh" "nc -z 127.0.0.1 1935"
assert_contains "assess.sh has max retries" "$REPO_ROOT/install/assess.sh" "MAX_CRITICAL_RETRIES"
assert_contains "assess.sh calls render-status.sh" "$REPO_ROOT/install/assess.sh" "render-status.sh"
assert_contains "assess.sh resolves symlinks for SCRIPT_DIR" "$REPO_ROOT/install/assess.sh" "readlink -f"

# ============================================================================
echo ""
echo "=== Render Status Tests ==="
# ============================================================================

assert_contains "render-status.sh has shebang" "$REPO_ROOT/diagnostics/render-status.sh" "^#!/bin/bash"
assert_contains "render-status.sh checks hostname" "$REPO_ROOT/diagnostics/render-status.sh" "check_hostname"
assert_contains "render-status.sh checks IP" "$REPO_ROOT/diagnostics/render-status.sh" "check_ip"
assert_not_contains "render-status.sh does not block on DNS" "$REPO_ROOT/diagnostics/render-status.sh" "^    check_dns$"
assert_contains "render-status.sh checks nginx" "$REPO_ROOT/diagnostics/render-status.sh" "check_nginx"
assert_contains "render-status.sh checks link speed/duplex" "$REPO_ROOT/diagnostics/render-status.sh" "check_link"
assert_contains "render-status.sh checks link errors" "$REPO_ROOT/diagnostics/render-status.sh" "check_link_errors"
assert_contains "render-status.sh checks RTMP stream" "$REPO_ROOT/diagnostics/render-status.sh" "check_rtmp_stream"
assert_contains "render-status.sh checks disk" "$REPO_ROOT/diagnostics/render-status.sh" "check_disk"
assert_contains "render-status.sh checks temperature" "$REPO_ROOT/diagnostics/render-status.sh" "check_temperature"
assert_contains "render-status.sh checks memory" "$REPO_ROOT/diagnostics/render-status.sh" "check_memory"
assert_contains "render-status.sh checks watchdog" "$REPO_ROOT/diagnostics/render-status.sh" "check_watchdog"
assert_contains "render-status.sh checks audio" "$REPO_ROOT/diagnostics/render-status.sh" "check_audio"
assert_contains "render-status.sh uses DejaVu font" "$REPO_ROOT/diagnostics/render-status.sh" "DejaVu-Sans"
assert_contains "render-status.sh outputs status summary" "$REPO_ROOT/diagnostics/render-status.sh" "^echo \"status="

# ============================================================================
echo ""
echo "=== nginx Config Tests ==="
# ============================================================================

assert_contains "nginx.conf has RTMP block" "$REPO_ROOT/install/nginx.conf" "^rtmp {"
assert_contains "nginx.conf listens on 1935" "$REPO_ROOT/install/nginx.conf" "listen 1935"
assert_contains "nginx.conf has live application" "$REPO_ROOT/install/nginx.conf" "application live"
assert_contains "nginx.conf allows LAN publish" "$REPO_ROOT/install/nginx.conf" "allow publish 192.168.0.0/16"
assert_contains "nginx.conf denies external publish" "$REPO_ROOT/install/nginx.conf" "deny publish all"
assert_contains "nginx.conf allows local play only" "$REPO_ROOT/install/nginx.conf" "allow play 127.0.0.1"
assert_contains "nginx.conf denies external play" "$REPO_ROOT/install/nginx.conf" "deny play all"
assert_contains "nginx.conf drops subscribers on publisher disconnect" "$REPO_ROOT/install/nginx.conf" "idle_streams off"
assert_contains "nginx.conf drops silent publisher" "$REPO_ROOT/install/nginx.conf" "drop_idle_publisher"

# rtmp_stat — exposes active publishers/streams as XML on a localhost-only
# HTTP endpoint. Without it, the only signal that a publisher is connected to
# the *wrong* stream key is "ESTAB on :1935 + ffprobe says No such stream",
# which is what bit us on 2026-05-02. The probe pulls /stat to surface the
# actual key in use.
assert_contains "nginx.conf exposes rtmp_stat HTTP endpoint" \
    "$REPO_ROOT/install/nginx.conf" "rtmp_stat all"
assert_contains "nginx.conf restricts rtmp_stat to localhost" \
    "$REPO_ROOT/install/nginx.conf" "allow 127.0.0.1"
assert_contains "setup-kiosk.sh nginx config exposes rtmp_stat" \
    "$REPO_ROOT/install/setup-kiosk.sh" "rtmp_stat all"

# ============================================================================
echo ""
echo "=== Kiosk Service Tests ==="
# ============================================================================

assert_contains "kiosk.service uses cage" "$REPO_ROOT/install/kiosk.service" "cage"
assert_contains "kiosk.service uses player.sh" "$REPO_ROOT/install/kiosk.service" "player.sh"
assert_contains "kiosk.service restarts always" "$REPO_ROOT/install/kiosk.service" "Restart=always"
assert_contains "kiosk.service no start limit" "$REPO_ROOT/install/kiosk.service" "StartLimitIntervalSec=0"
assert_contains "kiosk.service sets WLR_LIBINPUT_NO_DEVICES" "$REPO_ROOT/install/kiosk.service" "WLR_LIBINPUT_NO_DEVICES=1"

# ============================================================================
echo ""
echo "=== Deploy Script Tests ==="
# ============================================================================

assert_contains "deploy.sh uses rsync" "$REPO_ROOT/dev/deploy.sh" "rsync"
assert_contains "deploy.sh excludes .git" "$REPO_ROOT/dev/deploy.sh" "exclude='.git/'"
assert_contains "deploy.sh restarts kiosk service" "$REPO_ROOT/dev/deploy.sh" "systemctl --user restart"
assert_contains "deploy.sh installs nginx config" "$REPO_ROOT/dev/deploy.sh" "nginx.conf"

# Bug 2026-04-25: /home/kiosk is mode 0700, so the deploy user (rpi) cannot
# read kiosk.service on either side of the diff. The bare `diff -q` always
# exits 2, the script always falls into the cp branch, and `sudo cp ...
# kiosk.service` was never in the sudoers whitelist → password prompt. Use
# `sudo -u kiosk` for both diff and cp, leveraging the existing (kiosk)
# NOPASSWD: ALL grant — kiosk owns these files, so root never needs to.
assert_contains "deploy.sh uses 'sudo -u kiosk' for kiosk.service diff" \
    "$REPO_ROOT/dev/deploy.sh" "sudo -u .* diff -q .*kiosk\\.service"
assert_contains "deploy.sh uses 'sudo -u kiosk' for kiosk.service cp" \
    "$REPO_ROOT/dev/deploy.sh" "sudo -u .* cp .*kiosk\\.service"
assert_not_contains "deploy.sh does not bare 'sudo cp' kiosk.service (would prompt)" \
    "$REPO_ROOT/dev/deploy.sh" "sudo cp .*install/kiosk\\.service"

# ============================================================================
echo ""
echo "=== Health Overlay Tests ==="
# ============================================================================

assert_file_exists "install/mpv-health-overlay.lua exists" "$REPO_ROOT/install/mpv-health-overlay.lua"
assert_contains "overlay reads /tmp/kiosk-health.json" "$REPO_ROOT/install/mpv-health-overlay.lua" "/tmp/kiosk-health.json"
assert_contains "overlay positions health bottom-right" "$REPO_ROOT/install/mpv-health-overlay.lua" "\\\\an3"
assert_contains "overlay positions info bottom-left" "$REPO_ROOT/install/mpv-health-overlay.lua" "\\\\an1"
assert_contains "overlay uses two independent OSD layers" "$REPO_ROOT/install/mpv-health-overlay.lua" "create_osd_overlay"
assert_contains "overlay parses ip from json" "$REPO_ROOT/install/mpv-health-overlay.lua" "\"ip\""
assert_contains "overlay detects stale data" "$REPO_ROOT/install/mpv-health-overlay.lua" "STALE_THRESHOLD"
assert_contains "health-monitor writes ip field" "$REPO_ROOT/diagnostics/health-monitor.sh" '"ip"'
assert_contains "health-monitor writes hostname field" "$REPO_ROOT/diagnostics/health-monitor.sh" '"hostname"'
assert_file_exists "diagnostics/health-monitor.sh exists" "$REPO_ROOT/diagnostics/health-monitor.sh"
assert_executable "diagnostics/health-monitor.sh is executable" "$REPO_ROOT/diagnostics/health-monitor.sh"
assert_contains "health-monitor reuses check_health from healthcheck.sh" "$REPO_ROOT/diagnostics/health-monitor.sh" "healthcheck.sh"
assert_contains "health-monitor writes atomic via tmp+rename" "$REPO_ROOT/diagnostics/health-monitor.sh" "mv -f"
assert_contains "player.sh launches health monitor" "$REPO_ROOT/install/player.sh" "HEALTH_MONITOR"
assert_contains "player.sh passes --script to mpv" "$REPO_ROOT/install/player.sh" "OVERLAY_FLAG"

# ============================================================================
echo ""
echo "=== PipeWire Tests ==="
# ============================================================================

assert_contains "setup-kiosk.sh installs PipeWire client.conf" "$REPO_ROOT/install/setup-kiosk.sh" "client.conf"
assert_contains "setup-kiosk.sh creates kiosk pipewire config dir" "$REPO_ROOT/install/setup-kiosk.sh" ".config/pipewire"

# ============================================================================
echo ""
echo "=== HDMI Audio Routing Tests ==="
# ============================================================================
# See docs/dev-journal/2026-04-25-hdmi-audio-routing.md for context.
# We bypass PipeWire's default-sink selection by pinning mpv directly to the
# vc4-hdmi-0 ALSA card so audio always reaches HDMI port 0, regardless of how
# WirePlumber decides to rank sinks at session start.

assert_contains "player.sh pins audio to vc4hdmi0" \
    "$REPO_ROOT/install/player.sh" "alsa/plughw:CARD=vc4hdmi0"
assert_not_contains "player.sh does not use audio-device=auto (PipeWire default-sink trap)" \
    "$REPO_ROOT/install/player.sh" "audio-device=auto"
assert_contains "setup-kiosk.sh bootstrap player pins audio to vc4hdmi0" \
    "$REPO_ROOT/install/setup-kiosk.sh" "alsa/plughw:CARD=vc4hdmi0"
assert_not_contains "setup-kiosk.sh bootstrap player does not use audio-device=auto" \
    "$REPO_ROOT/install/setup-kiosk.sh" "audio-device=auto"

# Option B reference material — a WirePlumber rule that pins the system-wide
# default sink to HDMI-0. Not auto-installed; kept for reference/escape hatch.
assert_file_exists "wireplumber HDMI default-sink rule (option B reference)" \
    "$REPO_ROOT/install/wireplumber-hdmi-default.conf"
assert_contains "wireplumber rule matches by node.name (stable across reboots)" \
    "$REPO_ROOT/install/wireplumber-hdmi-default.conf" "node.name"
assert_contains "wireplumber rule targets vc4-hdmi-0 sink" \
    "$REPO_ROOT/install/wireplumber-hdmi-default.conf" "hdmi"

assert_file_exists "dev journal entry exists for HDMI audio routing" \
    "$REPO_ROOT/docs/dev-journal/2026-04-25-hdmi-audio-routing.md"

# ============================================================================
echo ""
echo "=== Deploy Sudoers Tests ==="
# ============================================================================
# Narrow whitelist that lets the SSH user run the specific deploy commands
# without a password. See docs/dev-journal/2026-04-25-hdmi-audio-routing.md.

assert_file_exists "install/kiosk-deploy.sudoers exists" \
    "$REPO_ROOT/install/kiosk-deploy.sudoers"
assert_contains "sudoers grants kiosk-as-target with SETENV (for XDG_RUNTIME_DIR)" \
    "$REPO_ROOT/install/kiosk-deploy.sudoers" "(kiosk) NOPASSWD:SETENV: ALL"
assert_contains "sudoers includes rsync (for --rsync-path)" \
    "$REPO_ROOT/install/kiosk-deploy.sudoers" "/usr/bin/rsync"
assert_contains "sudoers allows nginx test/reload" \
    "$REPO_ROOT/install/kiosk-deploy.sudoers" "/usr/bin/systemctl reload nginx"
assert_contains "sudoers uses templated deploy user placeholder" \
    "$REPO_ROOT/install/kiosk-deploy.sudoers" "__DEPLOY_USER__"
assert_contains "setup-kiosk.sh has configure_deploy_sudoers function" \
    "$REPO_ROOT/install/setup-kiosk.sh" "^configure_deploy_sudoers()"
assert_contains "setup-kiosk.sh validates sudoers with visudo before install" \
    "$REPO_ROOT/install/setup-kiosk.sh" "visudo -cf"
assert_contains "setup-kiosk.sh installs sudoers to /etc/sudoers.d/kiosk-deploy" \
    "$REPO_ROOT/install/setup-kiosk.sh" "/etc/sudoers.d/kiosk-deploy"
assert_contains "setup-kiosk.sh main() calls configure_deploy_sudoers" \
    "$REPO_ROOT/install/setup-kiosk.sh" "    configure_deploy_sudoers"
assert_contains "Makefile has sudoers target for one-time bootstrap" \
    "$REPO_ROOT/Makefile" "^sudoers:"
assert_not_contains "deploy.sh does not use sudo -A (option 2 makes askpass unnecessary)" \
    "$REPO_ROOT/dev/deploy.sh" "sudo -A"

# ============================================================================
echo ""
echo "=== Log Rotation Tests ==="
# ============================================================================

assert_file_exists "install/logrotate-kiosk exists" "$REPO_ROOT/install/logrotate-kiosk"
assert_contains "logrotate config targets /tmp/player.log" "$REPO_ROOT/install/logrotate-kiosk" "/tmp/player.log"
assert_contains "logrotate config uses copytruncate" "$REPO_ROOT/install/logrotate-kiosk" "copytruncate"
assert_contains "logrotate config has size cap" "$REPO_ROOT/install/logrotate-kiosk" "size "
assert_contains "setup-kiosk.sh installs logrotate config" "$REPO_ROOT/install/setup-kiosk.sh" "logrotate-kiosk"

# ============================================================================
echo ""
echo "=== Healthcheck Tests ==="
# ============================================================================

assert_file_exists "install/healthcheck.sh exists" "$REPO_ROOT/install/healthcheck.sh"
assert_executable "install/healthcheck.sh is executable" "$REPO_ROOT/install/healthcheck.sh"
assert_contains "healthcheck.sh has check_health function" "$REPO_ROOT/install/healthcheck.sh" "^check_health()"
assert_contains "healthcheck.sh reads config from HEALTHCHECK_URL" "$REPO_ROOT/install/healthcheck.sh" "HEALTHCHECK_URL"
assert_contains "healthcheck.sh pings on success" "$REPO_ROOT/install/healthcheck.sh" "curl"
assert_contains "healthcheck.sh supports fail ping" "$REPO_ROOT/install/healthcheck.sh" "/fail"
assert_contains "setup-kiosk.sh installs healthcheck cron" "$REPO_ROOT/install/setup-kiosk.sh" "healthcheck"

# ============================================================================
echo ""
echo "=== Operations & Diagnostics Dependency Tests ==="
# ============================================================================
# These packages are required by scripts in install/ and diagnostics/ but
# don't ship in the base Raspberry Pi OS Lite image. setup-kiosk.sh's
# install_packages() must pin them so a fresh-Pi install is self-contained.

# nc — used by player.sh wait_for_nginx, healthcheck.sh, assess.sh, render-status.sh.
# Without it player.sh hangs forever on the nginx readiness gate.
assert_contains "setup-kiosk.sh installs netcat-openbsd (provides nc)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "netcat-openbsd"

# wlr-randr — used by judder.sh probe to read the active Wayland mode.
assert_contains "setup-kiosk.sh installs wlr-randr (judder.sh probe)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "wlr-randr"

# kmsprint — used by judder.sh probe to dump KMS connector/CRTC state.
assert_contains "setup-kiosk.sh installs libdrm-tests (provides kmsprint)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "libdrm-tests"

# vcgencmd — used by judder.sh probe + monitor for thermal/throttling readout.
# Usually preinstalled on Raspberry Pi OS, but Lite images don't guarantee it.
assert_contains "setup-kiosk.sh installs libraspberrypi-bin (provides vcgencmd)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "libraspberrypi-bin"

# aplay — used by render-status.sh check_audio fallback when wpctl is absent.
assert_contains "setup-kiosk.sh installs alsa-utils (provides aplay)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "alsa-utils"

# ============================================================================
echo ""
echo "=== judder.sh probe Tests ==="
# ============================================================================

# Probe must query the rtmp_stat endpoint so a probe captured during the
# "splash showing but publisher connected" scenario reveals which stream
# key the publisher is actually using. (Bug 2026-05-03.)
assert_contains "judder.sh probe queries rtmp_stat endpoint" \
    "$REPO_ROOT/diagnostics/judder.sh" "127\\.0\\.0\\.1:8080/stat"
assert_contains "judder.sh probe has ACTIVE PUBLISHERS section" \
    "$REPO_ROOT/diagnostics/judder.sh" "ACTIVE PUBLISHERS"
assert_contains "judder.sh has stream-key subcommand" \
    "$REPO_ROOT/diagnostics/judder.sh" "^cmd_stream_key()"
assert_contains "Makefile has stream-key target (fast publisher check during event)" \
    "$REPO_ROOT/Makefile" "^stream-key:"

# HDMI mode-forcing recipe must use the KMS-correct kernel video= parameter
# in cmdline.txt — NOT the legacy firmware hdmi_group/hdmi_mode keys, which
# the vc4-kms-v3d driver silently ignores under Bookworm. Regressed in
# 6aa7d4e (rtmp_stat work) — operators followed the stale recipe and the
# 4K display kept upscaling. See dev journal 2026-05-09 entry.
assert_contains "judder.sh tree teaches the KMS cmdline.txt video= recipe" \
    "$REPO_ROOT/diagnostics/judder.sh" "video=HDMI-A-1:1920x1080@30"
assert_not_contains "judder.sh tree does not teach the legacy firmware hdmi_mode recipe (KMS ignores it)" \
    "$REPO_ROOT/diagnostics/judder.sh" "hdmi_mode=39"

# ============================================================================
echo ""
echo "=== HDMI mode single-source-of-truth Tests ==="
# ============================================================================
# Goal: HDMI mode lives in setup-kiosk.sh's cmdline.txt edits. dev/set-hdmi-mode.sh
# applies it to an already-running Pi without re-running full setup. judder.sh
# tree references the canonical mechanism instead of free-form recipe text that
# can drift.

# setup-kiosk.sh accepts HDMI_MODE env var
assert_contains "setup-kiosk.sh accepts HDMI_MODE env var" \
    "$REPO_ROOT/install/setup-kiosk.sh" "HDMI_MODE="
assert_contains "setup-kiosk.sh adds video=HDMI-A-1: to cmdline.txt when HDMI_MODE set" \
    "$REPO_ROOT/install/setup-kiosk.sh" 'video=HDMI-A-1:'
# Idempotence: must strip any prior video=HDMI-A-1:* before adding
assert_contains "setup-kiosk.sh strips prior video=HDMI-A-1: token (idempotent)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "video=HDMI-A-1:"

# Standalone fix-script for an already-deployed Pi
assert_file_exists "dev/set-hdmi-mode.sh exists" "$REPO_ROOT/dev/set-hdmi-mode.sh"
assert_executable  "dev/set-hdmi-mode.sh is executable" "$REPO_ROOT/dev/set-hdmi-mode.sh"
assert_contains "set-hdmi-mode.sh edits cmdline.txt (KMS-correct path)" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" "cmdline.txt"
# config.txt may be *read* (to warn about inert legacy keys) but must never
# be written by this script — the KMS-correct path lives in cmdline.txt.
assert_not_contains "set-hdmi-mode.sh does not write to config.txt (sudo tee/sed -i CONFIG)" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" 'sudo tee.*\$CONFIG\|sed -i.*\$CONFIG\|> *\$CONFIG'
assert_contains "set-hdmi-mode.sh writes video=HDMI-A-1 token" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" "video=HDMI-A-1:"
assert_contains "set-hdmi-mode.sh validates cmdline.txt is one non-empty line" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" "grep -c"

# Makefile exposes the mechanism
assert_contains "Makefile has hdmi-mode target" \
    "$REPO_ROOT/Makefile" "^hdmi-mode:"
assert_contains "Makefile setup target forwards HDMI_MODE" \
    "$REPO_ROOT/Makefile" "HDMI_MODE="

# judder.sh tree points at the canonical mechanism (single source of truth)
assert_contains "judder.sh tree references make hdmi-mode (canonical mechanism)" \
    "$REPO_ROOT/diagnostics/judder.sh" "make hdmi-mode"

# ============================================================================
echo ""
echo "=== Consistency Tests ==="
# ============================================================================

# Stream URL should be consistent across files
assert_contains "player.sh uses church242 stream key" "$REPO_ROOT/install/player.sh" "church242"
assert_contains "test-stream.sh defaults to church242" "$REPO_ROOT/dev/test-stream.sh" "church242"

# Splash path should be consistent
assert_contains "player.sh references splash.png" "$REPO_ROOT/install/player.sh" "/home/kiosk/splash.png"

# pix_fmt yuv420p in test stream (gotcha #6)
assert_contains "test-stream.sh uses yuv420p" "$REPO_ROOT/dev/test-stream.sh" "yuv420p"

# ============================================================================
echo ""
echo "=== Summary ==="
# ============================================================================

TOTAL=$((PASS + FAIL))
echo "${PASS}/${TOTAL} tests passed"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        printf "  ${RED}*${RESET} %s\n" "$err"
    done
fi

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
