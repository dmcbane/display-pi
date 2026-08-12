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

assert_file_absent() {
    local desc="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$desc: file still present at $path")
        printf "${RED}  FAIL${RESET} %s (still present: %s)\n" "$desc" "$path"
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
assert_file_exists "install/become-kiosk.sh exists" "$REPO_ROOT/install/become-kiosk.sh"
assert_executable  "install/become-kiosk.sh is executable" "$REPO_ROOT/install/become-kiosk.sh"
assert_file_exists "install/become-kiosk-web.sh exists" "$REPO_ROOT/install/become-kiosk-web.sh"
assert_executable  "install/become-kiosk-web.sh is executable" "$REPO_ROOT/install/become-kiosk-web.sh"
assert_file_exists "install/splash-store.sh exists" "$REPO_ROOT/install/splash-store.sh"
assert_executable  "install/splash-store.sh is executable" "$REPO_ROOT/install/splash-store.sh"
assert_file_exists "install/kiosk-config.sh exists" "$REPO_ROOT/install/kiosk-config.sh"
assert_executable  "install/kiosk-config.sh is executable" "$REPO_ROOT/install/kiosk-config.sh"
assert_file_exists "Makefile exists" "$REPO_ROOT/Makefile"
assert_file_exists "images/splash.png exists" "$REPO_ROOT/images/splash.png"
# Orphaned authoring tool: nothing in the repo, the Makefile, or the docs ever
# called it, and it shipped world-writable (0777).
assert_file_absent "images/overlay_fade_gif.py is gone (unreferenced tool)" \
    "$REPO_ROOT/images/overlay_fade_gif.py"
assert_file_exists  "install/kiosk-status.sh exists"        "$REPO_ROOT/install/kiosk-status.sh"
assert_executable   "install/kiosk-status.sh is executable" "$REPO_ROOT/install/kiosk-status.sh"
assert_file_exists "web/kiosk_manager.py exists" "$REPO_ROOT/web/kiosk_manager.py"
assert_file_exists "install/kiosk-web.service exists" "$REPO_ROOT/install/kiosk-web.service"
# LAN-facing Flask/Pillow surface that holds a sudo grant to reboot — sandbox
# it. NoNewPrivileges/PrivateTmp are intentionally NOT set (they'd break the
# sudo calls and the /tmp/kiosk-health.json read). The service writes only its
# two /var/lib dirs, declared via ReadWritePaths under ProtectSystem=strict.
assert_contains "kiosk-web.service runs as the locked kiosk-web user" \
    "$REPO_ROOT/install/kiosk-web.service" "User=kiosk-web"
assert_contains "kiosk-web.service sets ProtectSystem=strict" \
    "$REPO_ROOT/install/kiosk-web.service" "ProtectSystem=strict"
assert_contains "kiosk-web.service allows writes only to its state/splash dirs" \
    "$REPO_ROOT/install/kiosk-web.service" "ReadWritePaths=/var/lib/kiosk-web /var/lib/kiosk-splash"
assert_contains "kiosk-web.service protects home" \
    "$REPO_ROOT/install/kiosk-web.service" "ProtectHome="
assert_not_contains "kiosk-web.service does NOT set NoNewPrivileges (would break sudo reboot)" \
    "$REPO_ROOT/install/kiosk-web.service" "NoNewPrivileges=yes"
assert_not_contains "kiosk-web.service does NOT set PrivateTmp (would break health-file read)" \
    "$REPO_ROOT/install/kiosk-web.service" "PrivateTmp=yes"
assert_file_exists "install/kiosk-web.sudoers exists" "$REPO_ROOT/install/kiosk-web.sudoers"
assert_file_exists "install/kiosk-web-setup.sh exists" "$REPO_ROOT/install/kiosk-web-setup.sh"
assert_executable  "install/kiosk-web-setup.sh is executable" "$REPO_ROOT/install/kiosk-web-setup.sh"

# ============================================================================
echo ""
echo "=== Player Script Tests ==="
# ============================================================================

assert_contains "player.sh uses v4l2m2m-copy hwdec (Pi 4 native; avoids CUDA/Vulkan/VDPAU probes)" \
    "$REPO_ROOT/install/player.sh" "hwdec=v4l2m2m-copy"
assert_not_contains "player.sh does not use --hwdec=auto-safe (trips CUDA/Vulkan/VDPAU on Pi 4)" \
    "$REPO_ROOT/install/player.sh" "hwdec=auto-safe"
# --video-sync=audio is the chosen sync strategy: empirically eliminates judder
# on the ATEM→Pi→ONN 4K stack. display-resample re-resampled audio every frame
# and produced the judder; --video-sync=audio (mpv's default, but pinned here
# for clarity) lets video frames be duped/dropped instead. See dev-journal
# 2026-05-31-audio-sync-default.md.
assert_contains "player.sh uses --video-sync=audio (judder fix)" \
    "$REPO_ROOT/install/player.sh" "video-sync=audio"
assert_not_contains "player.sh does not use display-resample (caused judder)" \
    "$REPO_ROOT/install/player.sh" "video-sync=display-resample"
assert_contains "player.sh has shebang" "$REPO_ROOT/install/player.sh" "^#!/bin/bash"
assert_contains "player.sh has set -u" "$REPO_ROOT/install/player.sh" "^set -u"
assert_contains "player.sh references assess.sh" "$REPO_ROOT/install/player.sh" "assess.sh"
assert_contains "player.sh has nginx readiness gate" "$REPO_ROOT/install/player.sh" "nc -z 127.0.0.1 1935"
assert_contains "player.sh has stream_live function" "$REPO_ROOT/install/player.sh" "^stream_live()"
assert_contains "player.sh uses ffprobe with timeout" "$REPO_ROOT/install/player.sh" "timeout.*ffprobe"

# Detection latency (2026-07-03): the splash->stream switch is gated by how
# often the idle loop re-probes for a live publisher. The original `sleep 3`
# meant up to ~3s of splash-after-live lag — enough that a `make test-stream`
# looked like it "wasn't triggering." ffprobe fails fast (~0.45s) against an
# idle stream, so a 1s poll is cheap. The interval is a named, env-overridable
# constant so it's tunable and self-documenting.
assert_contains "player.sh defines a stream-detection poll interval" \
    "$REPO_ROOT/install/player.sh" "STREAM_POLL_INTERVAL"
assert_contains "player.sh idle re-probe interval defaults to 1s (fast splash->stream switch)" \
    "$REPO_ROOT/install/player.sh" 'STREAM_POLL_INTERVAL:-1'
assert_contains "player.sh idle wait loop polls at STREAM_POLL_INTERVAL" \
    "$REPO_ROOT/install/player.sh" 'sleep "\$STREAM_POLL_INTERVAL"'
assert_not_contains "player.sh no longer polls every 3s while waiting for the stream (slow switch)" \
    "$REPO_ROOT/install/player.sh" "sleep 3"
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

# nearest_refresh_for: maps an operator-friendly mode string like
# "1920x1080@30" to the closest refresh actually reported by wlr-randr for
# that resolution (e.g. "1920x1080@30.003000"). Pi 5 / Trixie regression
# 2026-06-13: wlr-randr does an exact string match on @RATE, and the GWD
# ARZOPA panel reports its 30Hz mode as 30.003 Hz — exact "@30" was
# rejected as "unknown mode", display defaulted to 60Hz, cage's atomic
# commits failed (kernel video= had synthesized a phantom 30Hz mode), and
# the screen went black. The resolver lets force_display_mode handle both
# panels that report 30.000 and panels that report 30.003/29.97/etc.
assert_contains "player.sh defines nearest_refresh_for resolver" \
    "$REPO_ROOT/install/player.sh" "^nearest_refresh_for()"
assert_contains "player.sh force_display_mode calls nearest_refresh_for" \
    "$REPO_ROOT/install/player.sh" "nearest_refresh_for"

# Behavior test: extract the function and exercise it on canned wlr-randr
# output. Same pattern as drops_behavior_test above.
nearest_refresh_behavior_test() {
    local fn_body
    fn_body=$(sed -n '/^nearest_refresh_for()/,/^}/p' "$REPO_ROOT/install/player.sh")
    if [[ -z "$fn_body" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("nearest_refresh_for behavior: function not found")
        printf "${RED}  FAIL${RESET} nearest_refresh_for behavior (function missing)\n"
        return
    fi
    local canned
    canned=$'HDMI-A-1 "GWD ARZOPA"\n  Modes:\n    1920x1080 px, 60.000000 Hz (preferred, current)\n    1920x1080 px, 144.001007 Hz\n    1920x1080 px, 30.003000 Hz\n    1280x720 px, 60.000000 Hz\n'

    for case in \
        '1920x1080@30:1920x1080@30.003000' \
        '1920x1080@60:1920x1080@60.000000' \
        '1280x720@30:1280x720@60.000000' \
        '3840x2160@30:'; do
        local target="${case%%:*}"
        local want="${case#*:}"
        local actual
        actual=$(bash -c "$fn_body
printf '%s' \"\$1\" | nearest_refresh_for '$target'" _ "$canned")
        if [[ "$actual" == "$want" ]]; then
            PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} nearest_refresh_for '%s' -> '%s'\n" "$target" "$want"
        else
            FAIL=$((FAIL + 1))
            ERRORS+=("nearest_refresh_for '$target': expected '$want' got '$actual'")
            printf "${RED}  FAIL${RESET} nearest_refresh_for '%s' (expected '%s', got '%s')\n" "$target" "$want" "$actual"
        fi
    done
}
nearest_refresh_behavior_test

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

# The status screen must show which stream/key the player subscribes to and
# which publishers are actually connected (via rtmp_stat): a publisher pushing
# to the wrong key otherwise looks identical to "no stream" on screen (the
# 2026-05-03 splash-stuck failure mode).
assert_contains "render-status.sh stream URL is env-overridable, default matches player" \
    "$REPO_ROOT/diagnostics/render-status.sh" 'STREAM_URL:-rtmp://127\.0\.0\.1/live/restoration'
assert_contains "render-status.sh shows the configured player stream/key" \
    "$REPO_ROOT/diagnostics/render-status.sh" "check_player_config"
assert_contains "render-status.sh lists connected publishers" \
    "$REPO_ROOT/diagnostics/render-status.sh" "check_publishers"
assert_contains "render-status.sh queries the rtmp_stat endpoint" \
    "$REPO_ROOT/diagnostics/render-status.sh" "127\\.0\\.0\\.1:8080/stat"
assert_contains "render-status.sh delegates stat parsing to parse_stat.py" \
    "$REPO_ROOT/diagnostics/render-status.sh" "parse_stat.py"
assert_not_contains "render-status.sh ffprobe check no longer hardcodes the stream URL" \
    "$REPO_ROOT/diagnostics/render-status.sh" '"rtmp://127\.0\.0\.1/live/restoration"'

# Checks must run concurrently (background jobs + wait): render-status.sh is
# on the boot path via assess.sh, and the serial worst case sums a 5s ffprobe
# timeout, a 3s curl timeout, and a dozen smaller probes.
assert_contains "render-status.sh runs checks as background jobs" \
    "$REPO_ROOT/diagnostics/render-status.sh" '2>/dev/null &$'
assert_contains "render-status.sh waits for all checks before rendering" \
    "$REPO_ROOT/diagnostics/render-status.sh" "^wait$"

# ============================================================================
echo ""
echo "=== nginx Config Tests ==="
# ============================================================================

assert_contains "nginx.conf has RTMP block" "$REPO_ROOT/install/nginx.conf" "^rtmp {"
assert_contains "nginx.conf listens on 1935" "$REPO_ROOT/install/nginx.conf" "listen 1935"
assert_contains "nginx.conf has live application" "$REPO_ROOT/install/nginx.conf" "application live"
# Publish is restricted to the wired /24 the ATEM encoder lives on — NOT the
# broad /16 + 10/8 (which trusted any private host). The stream key is not a
# secret (it's shown on the status board), so the CIDR is the real control
# against a LAN host hijacking the worship display.
assert_contains "nginx.conf restricts publish to the wired 192.168.0.0/24" \
    "$REPO_ROOT/install/nginx.conf" "allow publish 192.168.0.0/24"
assert_not_contains "nginx.conf no longer allows the broad /16 publish range" \
    "$REPO_ROOT/install/nginx.conf" "allow publish 192.168.0.0/16"
assert_not_contains "nginx.conf no longer allows the 10.0.0.0/8 publish range" \
    "$REPO_ROOT/install/nginx.conf" "allow publish 10.0.0.0/8"
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
# nginx-rtmp keeps stream state PER WORKER and does not share it: with
# worker_processes auto (4 on a Pi 4) the publisher lands on one worker while
# /stat queries and mpv subscriptions land on random others — /stat usually
# shows no publisher and the player can sit on splash retrying until it
# happens to hit the publisher's worker (observed 2026-07-05). One worker is
# plenty for one RTMP stream + the proxied web manager, and makes /stat and
# playback deterministic.
assert_contains "nginx.conf pins a single worker (nginx-rtmp state is per-worker)" \
    "$REPO_ROOT/install/nginx.conf" "^worker_processes 1;"
assert_not_contains "nginx.conf does not use worker_processes auto (breaks rtmp_stat/playback)" \
    "$REPO_ROOT/install/nginx.conf" "worker_processes auto"

assert_contains "nginx.conf exposes rtmp_stat HTTP endpoint" \
    "$REPO_ROOT/install/nginx.conf" "rtmp_stat all"
assert_contains "nginx.conf restricts rtmp_stat to localhost" \
    "$REPO_ROOT/install/nginx.conf" "allow 127.0.0.1"
# setup-kiosk.sh no longer heredocs its own nginx.conf — it renders the
# install/nginx.conf template (asserted above to expose rtmp_stat) through
# render-nginx-conf.sh, so the rtmp_stat guarantee lives in one place now.
assert_contains "setup-kiosk.sh renders nginx.conf from the shared template" \
    "$REPO_ROOT/install/setup-kiosk.sh" "render-nginx-conf.sh"

# Web-manager site block lives in a wildcard include so TLS config survives
# deploy.sh overwriting nginx.conf; the token is kept out of the access log.
assert_contains "nginx.conf includes web-manager site dir" \
    "$REPO_ROOT/install/nginx.conf" "include /etc/nginx/kiosk-web-site.d/\*.conf"
assert_contains "nginx.conf defines token-redacting log format" \
    "$REPO_ROOT/install/nginx.conf" "log_format kiosk_redacted"
assert_file_exists "HTTP web-manager site block exists" \
    "$REPO_ROOT/install/kiosk-web-site-http.conf"
assert_contains "web-manager site proxies to the Flask app" \
    "$REPO_ROOT/install/kiosk-web-site-http.conf" "proxy_pass         http://127.0.0.1:5000"
assert_contains "web-manager site redacts token from logs" \
    "$REPO_ROOT/install/kiosk-web-site-http.conf" "access_log /var/log/nginx/access.log kiosk_redacted"
assert_contains "deploy.sh seeds web-manager site block before reload" \
    "$REPO_ROOT/dev/deploy.sh" "kiosk-web-site.d"

# TLS setup: DNS-01 Let's Encrypt, HSTS, HTTP->HTTPS redirect, canonical URL.
assert_file_exists "TLS setup script exists" \
    "$REPO_ROOT/install/kiosk-web-tls-setup.sh"
assert_contains "TLS setup uses DNS-01 challenge" \
    "$REPO_ROOT/install/kiosk-web-tls-setup.sh" "preferred-challenges dns"
assert_contains "TLS setup sets HSTS header" \
    "$REPO_ROOT/install/kiosk-web-tls-setup.sh" "Strict-Transport-Security"
assert_contains "TLS setup redirects HTTP to HTTPS" \
    "$REPO_ROOT/install/kiosk-web-tls-setup.sh" "return 301 https"
assert_contains "TLS setup pins canonical PUBLIC_URL" \
    "$REPO_ROOT/install/kiosk-web-tls-setup.sh" "PUBLIC_URL=https"
assert_contains "TLS setup validates nginx before reload" \
    "$REPO_ROOT/install/kiosk-web-tls-setup.sh" "nginx -t"
assert_contains "TLS setup installs certbot on demand if missing" \
    "$REPO_ROOT/install/kiosk-web-tls-setup.sh" "apt-get install -y -qq certbot"

# The web manager's rotatable-token state dir is provisioned by both setup paths.
assert_contains "kiosk-web-setup.sh creates token state dir" \
    "$REPO_ROOT/install/kiosk-web-setup.sh" "/var/lib/kiosk-web"
assert_contains "kiosk-web-setup.sh defaults to local HTTPS" \
    "$REPO_ROOT/install/kiosk-web-setup.sh" "kiosk-web-tls-local.sh"

# Local-cert HTTPS: a per-Pi CA signs the server cert; HTTPS is the default and
# needs no domain. The root CA is fetchable over HTTP so devices can trust it.
assert_file_exists "local TLS script exists" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh"
assert_contains "local TLS signs a server cert with the local CA" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "openssl x509 -req"
assert_contains "local TLS sets Subject Alt Names (hostname + IPs)" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "subjectAltName"
assert_contains "local TLS verifies the cert chains to the CA" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "openssl verify -CAfile"
assert_contains "local TLS reuses the root CA across runs" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "Reusing existing root CA"
assert_contains "local TLS serves the root CA over HTTP for import" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "location = /rootCA.crt"
assert_contains "local TLS redirects HTTP to HTTPS" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "return 301 https"
assert_contains "local TLS sets HSTS header" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "Strict-Transport-Security"
assert_contains "local TLS pins canonical https PUBLIC_URL" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "PUBLIC_URL=https"
assert_contains "local TLS validates nginx before reload" \
    "$REPO_ROOT/install/kiosk-web-tls-local.sh" "nginx -t"
assert_contains "Makefile exposes setup-web-tls-local target" \
    "$REPO_ROOT/Makefile" "setup-web-tls-local:"
assert_contains "Makefile exposes web-ca fetch target" \
    "$REPO_ROOT/Makefile" "web-ca:"

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
# `systemctl --user` fails with "Failed to connect to user scope bus" unless
# DBUS_SESSION_BUS_ADDRESS points at the kiosk user's bus (learned in
# become-kiosk.sh, 2026-06-13). Every remote `systemctl --user` call site must
# carry it, not just XDG_RUNTIME_DIR.
assert_contains "deploy.sh sets DBUS_SESSION_BUS_ADDRESS for systemctl --user" \
    "$REPO_ROOT/dev/deploy.sh" "DBUS_SESSION_BUS_ADDRESS"
assert_contains "deploy.sh installs nginx config" "$REPO_ROOT/dev/deploy.sh" "nginx.conf"

# Anything sitting in the repo root rides the rsync to /home/kiosk/display-pi.
# That swept up local artifacts the operator never meant to ship — the
# .pytest_cache, the fetched root CA, and (worse) volunteer-kiosk.webloc /
# .url, which carry the live auth token. They are all already listed in
# .gitignore, so the deploy honors it as a dir-merge filter rather than
# maintaining a second, drifting copy of the same list.
assert_contains "deploy.sh honors .gitignore so local artifacts never reach the Pi" \
    "$REPO_ROOT/dev/deploy.sh" "filter=':- .gitignore'"

# Behavior test: run the REAL filter string from deploy.sh against a temp tree.
# A static grep can't tell a working filter from a typo'd one — rsync silently
# ignores a merge file it can't parse, and the token files would ship again.
deploy_gitignore_filter_test() {
    local filter tmp
    # `|| true`: no match is a test failure reported below, not a reason for
    # set -e to kill the whole runner mid-suite.
    filter=$(grep -o -- "--filter=':- .gitignore'" "$REPO_ROOT/dev/deploy.sh" | head -1 || true)
    if [[ -z "$filter" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("deploy gitignore filter: no --filter argument found in deploy.sh")
        printf "${RED}  FAIL${RESET} deploy.sh gitignore filter behavior (no filter arg)\n"
        return
    fi

    tmp=$(mktemp -d)
    mkdir -p "$tmp/src" "$tmp/dst"
    printf 'volunteer-kiosk.url\n.pytest_cache/\n' > "$tmp/src/.gitignore"
    : > "$tmp/src/volunteer-kiosk.url"
    : > "$tmp/src/player.sh"
    mkdir -p "$tmp/src/.pytest_cache"
    : > "$tmp/src/.pytest_cache/junk"

    # Word-split the filter exactly as the shell does in deploy.sh.
    eval "rsync -a $filter '$tmp/src/' '$tmp/dst/'" >/dev/null 2>&1

    if [[ -e "$tmp/dst/player.sh" && ! -e "$tmp/dst/volunteer-kiosk.url" && ! -e "$tmp/dst/.pytest_cache" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} deploy.sh rsync filter drops gitignored files, keeps tracked ones\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("deploy gitignore filter: token file or cache dir was transferred (or player.sh was not)")
        printf "${RED}  FAIL${RESET} deploy.sh rsync filter drops gitignored files, keeps tracked ones\n"
    fi
    rm -rf "$tmp"
}
deploy_gitignore_filter_test

# `make restart` bounces the kiosk service without a full deploy — used during
# testing to advance the splash rotation (player.sh re-enters the splash loop
# on restart and picks the next image). Same password-free path as deploy.
assert_contains "Makefile has restart target (manual kiosk restart)" \
    "$REPO_ROOT/Makefile" "^restart:"
assert_contains "Makefile restart target restarts kiosk.service" \
    "$REPO_ROOT/Makefile" "systemctl --user restart kiosk.service"
assert_contains "Makefile restart target uses the password-free 'sudo -u kiosk' path" \
    "$REPO_ROOT/Makefile" "sudo -u .* systemctl --user restart"
assert_contains "Makefile restart target sets DBUS_SESSION_BUS_ADDRESS for systemctl --user" \
    "$REPO_ROOT/Makefile" "DBUS_SESSION_BUS_ADDRESS"

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
assert_contains "overlay uses create_osd_overlay" "$REPO_ROOT/install/mpv-health-overlay.lua" "create_osd_overlay"
assert_contains "overlay detects stale data" "$REPO_ROOT/install/mpv-health-overlay.lua" "STALE_THRESHOLD"
# The overlay's stale window MUST match healthcheck.sh (-mmin -2) and the web
# board (HEALTH_STALE_SEC=120), else the screen flags STALE while the manager
# still shows green. Writer cadence is 20s, so 120s = 6 missed writes.
assert_contains "overlay stale threshold matches healthcheck/web board (120s)" \
    "$REPO_ROOT/install/mpv-health-overlay.lua" "STALE_THRESHOLD = 120"
# Hostname/IP watermark belongs only on the error/diagnostic screen
# (render-status.sh), never overlaid on the splash or live stream. The
# overlay must keep the bottom-right health corner but render no info corner.
assert_not_contains "overlay no longer renders an info corner (bottom-left)" "$REPO_ROOT/install/mpv-health-overlay.lua" "\\\\an1"
assert_not_contains "overlay no longer reads ip from json" "$REPO_ROOT/install/mpv-health-overlay.lua" "\"ip\""
assert_not_contains "overlay no longer reads hostname from json" "$REPO_ROOT/install/mpv-health-overlay.lua" "\"hostname\""
assert_not_contains "health-monitor no longer writes ip field" "$REPO_ROOT/diagnostics/health-monitor.sh" '"ip"'
assert_not_contains "health-monitor no longer writes hostname field" "$REPO_ROOT/diagnostics/health-monitor.sh" '"hostname"'
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

# backup_once must actually be "once": skip the backup when the source
# file is byte-identical to the most recent existing backup. Without this
# check, every idempotent `make setup` re-run accumulates a fresh
# timestamped copy across cmdline.txt, config.txt, nginx.conf, etc.
# (19 such files piled up across 3 re-runs on 2026-06-13).
assert_contains "backup_once finds most recent existing backup" \
    "$REPO_ROOT/install/setup-kiosk.sh" "ls -1t .*\\.bak-"
assert_contains "backup_once skips when content matches latest backup" \
    "$REPO_ROOT/install/setup-kiosk.sh" "cmp -s"
# pipefail kills the script when the glob is empty unless guarded with || true.
assert_contains "backup_once tolerates empty backup glob under pipefail" \
    "$REPO_ROOT/install/setup-kiosk.sh" "head -1 || true"
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
# Per TODO.md: visudo rpi all nopasswd as part of the setup. The narrow
# whitelist above is kept as documentation of which commands deploy needs,
# but the broad ALL=(ALL) NOPASSWD: ALL grant is what the operator
# explicitly asked for so the deploy user has unconditional passwordless
# sudo from any SSH session (e.g. for ad-hoc `make hdmi-mode` runs that
# touch /boot/firmware/cmdline.txt — a path NOT in the narrow list, see
# dev journal 2026-05-10 set-hdmi-mode-sudo-tty).
assert_contains "sudoers grants deploy user unconditional NOPASSWD: ALL" \
    "$REPO_ROOT/install/kiosk-deploy.sudoers" "ALL=(ALL) NOPASSWD: ALL"

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
echo "=== Locale / SSH Environment Tests ==="
# ============================================================================
# A fresh Raspberry Pi OS Lite image generates almost no locales, so an SSH
# client that forwards LANG/LC_* (the default on macOS and most desktops)
# triggers "cannot change locale" warnings at every login. configure_locale
# makes this deterministic regardless of the client: it generates a real
# default locale and strips LANG/LC_* from sshd's AcceptEnv so forwarded
# values are ignored entirely.

assert_contains "setup-kiosk.sh has configure_locale function" \
    "$REPO_ROOT/install/setup-kiosk.sh" "^configure_locale()"
assert_contains "setup-kiosk.sh defines a default locale" \
    "$REPO_ROOT/install/setup-kiosk.sh" "en_US.UTF-8"
assert_contains "configure_locale generates the locale" \
    "$REPO_ROOT/install/setup-kiosk.sh" "locale-gen"
assert_contains "configure_locale sets the system default LANG" \
    "$REPO_ROOT/install/setup-kiosk.sh" "update-locale LANG="
assert_contains "configure_locale neutralizes forwarded SSH locales" \
    "$REPO_ROOT/install/setup-kiosk.sh" "locale forwarding disabled"
assert_contains "configure_locale validates sshd before reload" \
    "$REPO_ROOT/install/setup-kiosk.sh" "sshd -t"
assert_contains "setup-kiosk.sh main() calls configure_locale" \
    "$REPO_ROOT/install/setup-kiosk.sh" "    configure_locale"

# Ordering matters as much as presence. configure_locale used to run as step
# 10d, near the end — so every apt invocation in install_packages (step 1) ran
# under a forwarded LANG that didn't exist on the Pi yet, and the operator
# watched perl and dpkg emit "cannot change locale" for the whole install.
# The function depends on nothing install_packages provides (locale-gen,
# update-locale, and sshd all ship in the base image), so it runs first.
locale_before_packages_test() {
    local main_body loc_line pkg_line
    main_body=$(sed -n '/^main() {/,/^}/p' "$REPO_ROOT/install/setup-kiosk.sh")
    loc_line=$(grep -n '^[[:space:]]*configure_locale[[:space:]]*$' <<<"$main_body" | head -1 | cut -d: -f1)
    pkg_line=$(grep -n '^[[:space:]]*install_packages[[:space:]]*$' <<<"$main_body" | head -1 | cut -d: -f1)

    # A missing call is a failure, not a silent pass — an empty line number
    # would otherwise make the comparison below vacuously true.
    if [[ -z "$loc_line" || -z "$pkg_line" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("locale ordering: configure_locale or install_packages not called in main()")
        printf "${RED}  FAIL${RESET} main() calls both configure_locale and install_packages\n"
        return
    fi
    if (( loc_line < pkg_line )); then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} main() runs configure_locale before install_packages\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("locale ordering: configure_locale (main line $loc_line) runs after install_packages (main line $pkg_line)")
        printf "${RED}  FAIL${RESET} main() runs configure_locale before install_packages (locale at %s, packages at %s)\n" \
            "$loc_line" "$pkg_line"
    fi
}
locale_before_packages_test

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
# On Pi OS 12 (Bookworm) vcgencmd ships in libraspberrypi-bin; on Pi OS 13
# (Trixie) that package is gone and vcgencmd lives in raspi-utils. The script
# must reference BOTH names and pick at runtime via apt-cache.
assert_contains "setup-kiosk.sh references raspi-utils (Trixie vcgencmd pkg)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "raspi-utils"
assert_contains "setup-kiosk.sh references libraspberrypi-bin (Bookworm vcgencmd pkg)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "libraspberrypi-bin"
assert_contains "setup-kiosk.sh picks vcgencmd pkg via apt-cache" \
    "$REPO_ROOT/install/setup-kiosk.sh" "apt-cache show raspi-utils"

# aplay — used by render-status.sh check_audio fallback when wpctl is absent.
assert_contains "setup-kiosk.sh installs alsa-utils (provides aplay)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "alsa-utils"

# machinectl — the post-install instructions tell the operator to run
# `sudo machinectl shell ${KIOSK_USER}@ /bin/bash -c "systemctl --user status …"`
# to peek at the kiosk user's user-scope units. machinectl ships in
# systemd-container, which Pi OS Lite does NOT preinstall.
assert_contains "setup-kiosk.sh installs systemd-container (provides machinectl)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "systemd-container"

# Post-install instructions printed at end of setup must use become-kiosk
# (the project's helper) instead of machinectl/-M kiosk@. machinectl shell
# works one-shot but `journalctl -M kiosk@` fails on Pi OS because the
# user manager is not registered as a machine with systemd-machined.
assert_contains "setup-kiosk.sh post-install uses become-kiosk for kiosk service status" \
    "$REPO_ROOT/install/setup-kiosk.sh" "become-kiosk systemctl --user status kiosk.service"
# journalctl can't go via become-kiosk: kiosk is not in systemd-journal group
# (would need explicit usermod -aG, with broader implications), so it can't
# read /run/log/journal/. Root reading the system journal with an explicit
# _SYSTEMD_USER_UNIT= match is the simplest reliable form on this image.
assert_contains "setup-kiosk.sh post-install uses sudo journalctl _SYSTEMD_USER_UNIT for logs" \
    "$REPO_ROOT/install/setup-kiosk.sh" "sudo journalctl _SYSTEMD_USER_UNIT=kiosk.service"
assert_not_contains "setup-kiosk.sh post-install no longer uses -M …KIOSK_USER@" \
    "$REPO_ROOT/install/setup-kiosk.sh" "KIOSK_USER}@"

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
# become-kiosk.sh: a one-shot helper to drop into the kiosk user's shell with
# XDG_RUNTIME_DIR set so `systemctl --user`, wpctl, and friends work. The
# script must (a) fall back to /run/user/$(id -u kiosk) when XDG_RUNTIME_DIR
# is unset (the common case when invoked from a plain SSH session), and
# (b) exec sudo -u kiosk so signals propagate to the child shell.
assert_contains "become-kiosk.sh execs sudo -u into the kiosk user" \
    "$REPO_ROOT/install/become-kiosk.sh" "exec sudo -u"
# XDG_RUNTIME_DIR must ALWAYS be set to the kiosk user's runtime dir, not
# the caller's. The old ${VAR:-default} fallback was a bug: when invoked
# from a deploy user's SSH session, pam_systemd had already set
# XDG_RUNTIME_DIR to /run/user/<deploy_uid>, so the fallback skipped and
# kiosk inherited the wrong path — DBUS lookups then connected to the
# DEPLOY user's bus (or failed). Script must overwrite unconditionally.
assert_contains "become-kiosk.sh always sets XDG_RUNTIME_DIR to kiosk uid" \
    "$REPO_ROOT/install/become-kiosk.sh" 'XDG_RUNTIME_DIR="/run/user/'
assert_not_contains "become-kiosk.sh does not inherit caller's XDG_RUNTIME_DIR" \
    "$REPO_ROOT/install/become-kiosk.sh" 'XDG_RUNTIME_DIR:-'
assert_contains "become-kiosk.sh passes XDG_RUNTIME_DIR through to sudo" \
    "$REPO_ROOT/install/become-kiosk.sh" "XDG_RUNTIME_DIR="
# Empirically (2026-06-13), sudo -u kiosk -i does NOT inherit a usable D-Bus
# user-bus address. systemctl --user fails with "Failed to connect to user
# scope bus via local transport: Operation not permitted" unless we set
# DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus explicitly.
assert_contains "become-kiosk.sh sets DBUS_SESSION_BUS_ADDRESS" \
    "$REPO_ROOT/install/become-kiosk.sh" "DBUS_SESSION_BUS_ADDRESS="
assert_contains "become-kiosk.sh derives DBUS_SESSION_BUS_ADDRESS from runtime dir" \
    "$REPO_ROOT/install/become-kiosk.sh" 'unix:path=\$XDG_RUNTIME_DIR/bus'
assert_contains "become-kiosk.sh defaults target user to kiosk" \
    "$REPO_ROOT/install/become-kiosk.sh" 'KIOSK_USER:-kiosk'
# The same DBUS lesson applies to setup-kiosk.sh's own `systemctl --user
# daemon-reload/enable` calls — they set XDG but were missing the bus address.
assert_contains "setup-kiosk.sh sets DBUS_SESSION_BUS_ADDRESS for its systemctl --user calls" \
    "$REPO_ROOT/install/setup-kiosk.sh" "DBUS_SESSION_BUS_ADDRESS"
# setup-kiosk.sh must install the operator helpers into /usr/local/bin so
# they can be run from any SSH session without needing to know the repo path.
assert_contains "setup-kiosk.sh installs the operator helpers into /usr/local/bin" \
    "$REPO_ROOT/install/setup-kiosk.sh" 'dst="/usr/local/bin/\${helper}"'
assert_contains "setup-kiosk.sh installs become-kiosk among them" \
    "$REPO_ROOT/install/setup-kiosk.sh" '\[become-kiosk\]=become-kiosk.sh' 

# kiosk user group memberships: video/render/input for DRM + input access,
# audio for ALSA. A 'seat' group entry was speculative — Debian/Trixie has
# no such group, and cage talks to seatd over a Unix socket with libseat
# auth (no POSIX group required). The bogus entry warned on every setup
# run with "Group 'seat' does not exist on this system; skipping."
assert_contains "setup-kiosk.sh group loop covers video/render/input/audio" \
    "$REPO_ROOT/install/setup-kiosk.sh" "for group in video render input audio"
assert_not_contains "setup-kiosk.sh group loop drops nonexistent 'seat' group" \
    "$REPO_ROOT/install/setup-kiosk.sh" "input seat audio"

assert_contains "Makefile has stream-key target (fast publisher check during event)" \
    "$REPO_ROOT/Makefile" "^stream-key:"

# cmd_variant must offer an explicit non-Ctrl-C exit path. The original
# implementation used `while true; do sleep 60; done` and relied on Ctrl-C
# triggering the EXIT trap — fine locally but unreliable over SSH and
# undiscoverable for an operator at the venue. Accept Enter (read -r) and
# surface `./judder.sh restore` in the on-screen instructions.
assert_contains "judder.sh variant accepts Enter to restore (read -r, not sleep-forever)" \
    "$REPO_ROOT/diagnostics/judder.sh" "read -r"
assert_not_contains "judder.sh variant does not busy-sleep forever (Ctrl-C only)" \
    "$REPO_ROOT/diagnostics/judder.sh" "while true; do sleep 60; done"
assert_contains "judder.sh variant tells operator to press Enter to restore" \
    "$REPO_ROOT/diagnostics/judder.sh" "Press Enter"
assert_contains "judder.sh variant surfaces './judder.sh restore' as a fallback exit path" \
    "$REPO_ROOT/diagnostics/judder.sh" "judder.sh restore"

# HDMI mode-forcing recipe must use the KMS-correct kernel video= parameter
# in /etc/default/kiosk (consumed at runtime by player.sh -> wlr-randr) —
# NOT the legacy firmware hdmi_group/hdmi_mode keys, which the vc4-kms-v3d
# driver silently ignores under Bookworm/Trixie. Also NOT the kernel
# video=HDMI-A-1: cmdline parameter — on Pi 5 / Trixie that synthesizes a
# modeline that wayland (cage) can't atomic-commit against (regression
# 2026-06-13 — black screen). See dev journal 2026-05-09 and the
# Pi 5 / Trixie black-screen note.
assert_contains "judder.sh tree teaches make hdmi-mode (canonical recipe)" \
    "$REPO_ROOT/diagnostics/judder.sh" "make hdmi-mode HDMI_MODE=1920x1080@30"
assert_not_contains "judder.sh tree does not teach the legacy firmware hdmi_mode recipe (KMS ignores it)" \
    "$REPO_ROOT/diagnostics/judder.sh" "hdmi_mode=39"
assert_not_contains "judder.sh tree no longer teaches manual cmdline.txt video= edit (breaks Pi 5/Trixie)" \
    "$REPO_ROOT/diagnostics/judder.sh" 'sudoedit /boot/firmware/cmdline.txt'

# judder.sh monitor: the drops counter must produce a single-line value.
# GNU grep -c on an empty file outputs "0" AND exits 1, so `grep -c … || echo 0`
# concatenates "0\n0" — the next arithmetic line (`$((drops - start_drops))`)
# then chokes with "syntax error in expression". Captured in TODO.txt, 2026-05-09.
assert_not_contains "judder.sh monitor drops counter avoids 'grep -c … || echo' (2-line bug)" \
    "$REPO_ROOT/diagnostics/judder.sh" "grep -ci 'drop' \"\$PLAYER_LOG\" 2>/dev/null || echo"

# Behavioral check: simulate the (fixed) drops snippet against the three real
# inputs we see at the venue — empty log, missing log, log with matches — and
# verify that arithmetic on the result works. Run as a sub-shell so the
# assertion failure mode is "this script chokes on a real log".
drops_behavior_test() {
    local desc tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    # Extract every line that assigns `drops=…` from the script and run it.
    # The fixed snippet must yield a single-line numeric value for all three
    # log states. We re-use the same shell logic the script uses.
    local snippet
    snippet=$(grep -E '^\s*drops=' "$REPO_ROOT/diagnostics/judder.sh" | head -2)
    if [[ -z "$snippet" ]]; then
        FAIL=$((FAIL + 1)); ERRORS+=("drops snippet not found in judder.sh")
        printf "${RED}  FAIL${RESET} drops snippet not found in judder.sh\n"
        return
    fi

    local empty="$tmp/empty.log"
    local missing="$tmp/no-such.log"
    local hits="$tmp/hits.log"
    : > "$empty"
    printf 'frame drop\nanother drop\n' > "$hits"

    for case in empty:"$empty":0 missing:"$missing":0 hits:"$hits":2; do
        local name="${case%%:*}"
        local rest="${case#*:}"
        local path="${rest%:*}"
        local want="${rest##*:}"
        local actual
        actual=$(PLAYER_LOG="$path" bash -c "$snippet"$'\necho "$drops"')
        local lines; lines=$(printf '%s' "$actual" | grep -c '' || true)
        if [[ "$lines" -ne 1 ]]; then
            FAIL=$((FAIL + 1))
            ERRORS+=("drops counter ($name log): expected 1-line output, got $lines lines: $(printf %q "$actual")")
            printf "${RED}  FAIL${RESET} drops counter (%s log) is single-line\n" "$name"
            continue
        fi
        if ! (( actual - 0 == want )) 2>/dev/null; then
            FAIL=$((FAIL + 1))
            ERRORS+=("drops counter ($name log): expected $want, got '$actual'")
            printf "${RED}  FAIL${RESET} drops counter (%s log) value: expected %s, got %s\n" "$name" "$want" "$actual"
            continue
        fi
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} drops counter (%s log) produces single-line numeric value\n" "$name"
    done
}
drops_behavior_test

# judder.sh rprobe: separate subcommand for the rolling probe (heavy variant of
# monitor). The original `output full probe results when monitoring` commit
# (705c935) ran cmd_probe unconditionally inside monitor's loop, making the
# light-weight tabular view unusable. rprobe gates the heavy probe behind an
# opt-in subcommand; monitor stays terse. Both must pass their flag as a
# SEPARATE positional arg — quoting "BRIEF $@" / "PROBE $@" collapses the
# flag and the interval into a single arg, silently dropping the interval.
assert_contains "judder.sh has rprobe subcommand (rolling probe)" \
    "$REPO_ROOT/diagnostics/judder.sh" "^    rprobe)"
assert_contains "judder.sh monitor dispatch passes BRIEF as a separate arg" \
    "$REPO_ROOT/diagnostics/judder.sh" "cmd_monitor BRIEF \"\\\$@\""
assert_contains "judder.sh rprobe dispatch passes PROBE as a separate arg" \
    "$REPO_ROOT/diagnostics/judder.sh" "cmd_monitor PROBE \"\\\$@\""
assert_not_contains "judder.sh monitor dispatch does not collapse flag+args into one quoted string" \
    "$REPO_ROOT/diagnostics/judder.sh" "cmd_monitor \"BRIEF \\\$@\""
assert_not_contains "judder.sh rprobe dispatch does not collapse flag+args into one quoted string" \
    "$REPO_ROOT/diagnostics/judder.sh" "cmd_monitor \"PROBE \\\$@\""
assert_contains "judder.sh usage documents rprobe subcommand" \
    "$REPO_ROOT/diagnostics/judder.sh" "rprobe \\[secs\\]"

# vcgencmd parsing: `vcgencmd get_throttled` emits `throttled=0x0` and
# `vcgencmd measure_clock arm` emits `frequency(N)=1800000000`. Splitting on
# `=` puts the value in field $2. A regression to $3 yields an empty value,
# and `arm=$((<empty>/1000000))` then fails as a bash arithmetic syntax
# error — under `set -u` the loop dies on first iteration, leaving
# /tmp/judder-monitor-*.log header-only. (Seen 2026-05-24.)
assert_contains "judder.sh monitor parses vcgencmd get_throttled at field \$2" \
    "$REPO_ROOT/diagnostics/judder.sh" "vcgencmd get_throttled 2>/dev/null | awk -F= '{print \\\$2}'"
assert_contains "judder.sh monitor parses vcgencmd measure_clock arm at field \$2" \
    "$REPO_ROOT/diagnostics/judder.sh" "vcgencmd measure_clock arm 2>/dev/null | awk -F= '{print \\\$2}'"

# Behavioral check: drive cmd_monitor's parsing pipeline with shimmed vcgencmd
# outputs matching the real device, confirm the values land in `thr` / `arm`
# as the tabular line expects (0x0 and 1800), and that the arithmetic on `arm`
# doesn't fault. This is the assertion that would have caught the $3 mistake.
vcgencmd_parse_behavior_test() {
    local thr arm
    thr=$(printf 'throttled=0x0\n' | awk -F= '{print $2}')
    arm=$(( $(printf 'frequency(48)=1800000000\n' | awk -F= '{print $2}') / 1000000 ))
    if [[ "$thr" == "0x0" && "$arm" -eq 1800 ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} vcgencmd parse: throttled=%s arm=%s (real-device format)\n" "$thr" "$arm"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("vcgencmd parse: expected thr=0x0 arm=1800, got thr=$thr arm=$arm")
        printf "${RED}  FAIL${RESET} vcgencmd parse: expected thr=0x0 arm=1800, got thr=%s arm=%s\n" "$thr" "$arm"
    fi
}
vcgencmd_parse_behavior_test

# ============================================================================
echo ""
echo "=== rtmp_stat parser Tests ==="
# ============================================================================
# The stat parser embedded in judder.sh (probe + stream-key) was demonstrably
# silent about subscriber-only and publisher-just-disconnected states: the
# 2026-05-23 monitor-5 log captured ffprobe reading h264/1920x1080 in the
# same probe block where the stat parser printed "no active streams" — the
# operator had no way to tell whether the publisher really was absent or the
# parser had silently misread the XML. Fix: extract the parser into a shared
# helper (diagnostics/parse_stat.py) and drive it from fixtures so future
# regressions surface in CI, and always persist the raw XML so the operator
# can verify the parsed output against the source.

assert_file_exists "diagnostics/parse_stat.py exists" "$REPO_ROOT/diagnostics/parse_stat.py"
assert_executable  "diagnostics/parse_stat.py is executable" "$REPO_ROOT/diagnostics/parse_stat.py"
# Judder script should delegate to the helper (no embedded heredoc parsers).
assert_contains "judder.sh delegates probe stat parsing to parse_stat.py" \
    "$REPO_ROOT/diagnostics/judder.sh" "parse_stat.py"
assert_not_contains "judder.sh has no embedded probe ET.fromstring (replaced by parse_stat.py)" \
    "$REPO_ROOT/diagnostics/judder.sh" "ET.fromstring"
# Probe should always save raw XML so an after-the-fact audit can confirm
# whether "no active publishers" was true at that instant.
assert_contains "judder.sh probe saves raw stat XML for post-hoc verification" \
    "$REPO_ROOT/diagnostics/judder.sh" "judder-stat-"

# Behavioral: run the helper against realistic nginx-rtmp stat XML fixtures.
parse_stat_behavior_test() {
    local helper="$REPO_ROOT/diagnostics/parse_stat.py"
    if [[ ! -x "$helper" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("parse_stat behavioral tests skipped: $helper missing or not executable")
        printf "${RED}  FAIL${RESET} parse_stat behavioral tests skipped (helper missing)\n"
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        ERRORS+=("parse_stat behavioral tests skipped: python3 unavailable")
        printf "${RED}  FAIL${RESET} parse_stat behavioral tests skipped (python3 missing)\n"
        return
    fi

    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" RETURN

    # Standard nginx-rtmp XML: <rtmp><server><application><name>live</name>
    # <live><nclients>2</nclients><stream>...<client><publishing/>...</client>
    # <client/></stream></live></application></server></rtmp>
    local xml_full="$tmp/full.xml"
    cat >"$xml_full" <<'XML'
<?xml version="1.0" encoding="utf-8" ?>
<rtmp>
  <nginx_version>1.22.1</nginx_version>
  <server>
    <application>
      <name>live</name>
      <live>
        <nclients>2</nclients>
        <stream>
          <name>restoration</name>
          <time>123456</time>
          <bw_in>7031032</bw_in>
          <client>
            <id>1</id>
            <address>192.168.0.108</address>
            <time>120000</time>
            <flashver>Blackmagic ATEM Mini Pro 9.5.1</flashver>
            <publishing/>
            <active/>
          </client>
          <client>
            <id>2</id>
            <address>127.0.0.1</address>
            <time>5000</time>
            <flashver>mpv</flashver>
            <active/>
          </client>
        </stream>
      </live>
    </application>
  </server>
</rtmp>
XML

    # Case 1: standard XML, publisher matches player's expected key.
    local out
    out=$("$helper" probe --expected-key restoration <"$xml_full" 2>&1) || true
    case "$out" in
        *"key=restoration"*"pub=192.168.0.108"*"matches player"*)
            PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat probe finds publisher in standard XML\n" ;;
        *)
            FAIL=$((FAIL + 1))
            ERRORS+=("parse_stat probe missed publisher in standard XML; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat probe missed publisher in standard XML\n" ;;
    esac

    # Case 2: same XML but no <server> wrapper — some nginx-rtmp builds emit
    # <rtmp><application>… directly. .//application makes this work; a tight
    # ./application would not.
    local xml_no_server="$tmp/no_server.xml"
    cat >"$xml_no_server" <<'XML'
<?xml version="1.0" encoding="utf-8" ?>
<rtmp>
  <application>
    <name>live</name>
    <live>
      <nclients>1</nclients>
      <stream>
        <name>restoration</name>
        <bw_in>6000000</bw_in>
        <client>
          <address>192.168.0.108</address>
          <flashver>ATEM</flashver>
          <publishing/>
        </client>
      </stream>
    </live>
  </application>
</rtmp>
XML
    out=$("$helper" probe --expected-key restoration <"$xml_no_server" 2>&1) || true
    case "$out" in
        *"key=restoration"*"pub=192.168.0.108"*) PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat probe handles XML without <server> wrapper\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat probe missed publisher when <server> absent; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat probe missed publisher when <server> absent\n" ;;
    esac

    # Case 3: stream key MISMATCH — publisher pushing to a different key than
    # the player expects. The 2026-05-03 splash-stuck failure mode.
    local xml_mismatch="$tmp/mismatch.xml"
    sed 's/restoration/wrongkey/' "$xml_full" >"$xml_mismatch"
    out=$("$helper" probe --expected-key restoration <"$xml_mismatch" 2>&1) || true
    case "$out" in
        *"MISMATCH"*"restoration"*) PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat probe flags key MISMATCH against expected key\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat probe did not flag mismatch; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat probe did not flag key MISMATCH\n" ;;
    esac

    # Case 4: publisher just disconnected — <live> remains briefly with
    # nclients>0 (subscribers waiting) but no <stream>. Parser must say so
    # explicitly, citing nclients, not just "no active streams".
    local xml_no_stream="$tmp/no_stream.xml"
    cat >"$xml_no_stream" <<'XML'
<?xml version="1.0" encoding="utf-8" ?>
<rtmp>
  <server>
    <application>
      <name>live</name>
      <live>
        <nclients>1</nclients>
      </live>
    </application>
  </server>
</rtmp>
XML
    out=$("$helper" probe --expected-key restoration <"$xml_no_stream" 2>&1) || true
    case "$out" in
        *"app=live"*"no publisher"*"nclients=1"*) PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat probe reports nclients when no stream is published\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat probe did not surface nclients on empty <live>; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat probe did not surface nclients on empty <live>\n" ;;
    esac

    # Case 5: subscribers only (stream entry exists with non-publisher clients).
    local xml_subs_only="$tmp/subs_only.xml"
    cat >"$xml_subs_only" <<'XML'
<?xml version="1.0" encoding="utf-8" ?>
<rtmp><server><application>
  <name>live</name>
  <live>
    <nclients>1</nclients>
    <stream>
      <name>restoration</name>
      <bw_in>0</bw_in>
      <client><address>127.0.0.1</address></client>
    </stream>
  </live>
</application></server></rtmp>
XML
    out=$("$helper" probe --expected-key restoration <"$xml_subs_only" 2>&1) || true
    case "$out" in
        *"key=restoration"*"no publisher"*) PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat probe distinguishes subscribers-only from no-stream\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat probe missed subscribers-only state; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat probe missed subscribers-only state\n" ;;
    esac

    # Case 6: stream-key mode emits the publisher's key and address.
    out=$("$helper" stream-key --expected-key restoration <"$xml_full" 2>&1) || true
    case "$out" in
        *"key=restoration"*"pub=192.168.0.108"*) PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat stream-key emits key+pub for standard XML\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat stream-key missed publisher; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat stream-key missed publisher\n" ;;
    esac

    # Case 7: invalid XML must produce a non-zero exit and an error on
    # stderr — never silently succeed (CLAUDE.md: NEVER SWALLOW ERRORS).
    local rc=0
    out=$(printf 'not xml' | "$helper" probe --expected-key restoration 2>&1) || rc=$?
    if [[ $rc -ne 0 && "$out" == *"parse"* ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} parse_stat surfaces XML parse error with non-zero exit\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("parse_stat swallowed XML parse error: rc=$rc out='$out'")
        printf "${RED}  FAIL${RESET} parse_stat swallowed XML parse error (rc=%s)\n" "$rc"
    fi

    # Case 8: XML with default namespace — older nginx-rtmp forks occasionally
    # emit one. The helper must strip namespaces so the parse still finds
    # <application> / <stream>.
    local xml_ns="$tmp/ns.xml"
    cat >"$xml_ns" <<'XML'
<?xml version="1.0" encoding="utf-8" ?>
<rtmp xmlns="http://nginx.org/rtmp">
  <application>
    <name>live</name>
    <live>
      <nclients>1</nclients>
      <stream>
        <name>restoration</name>
        <bw_in>1</bw_in>
        <client>
          <address>192.168.0.108</address>
          <publishing/>
        </client>
      </stream>
    </live>
  </application>
</rtmp>
XML
    out=$("$helper" probe --expected-key restoration <"$xml_ns" 2>&1) || true
    case "$out" in
        *"key=restoration"*"pub=192.168.0.108"*) PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat probe strips XML namespaces\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat probe failed on namespaced XML; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat probe failed on namespaced XML\n" ;;
    esac

    # Case 9: status mode — render-status.sh rows ("STATUS|label|detail").
    # Matching publisher is OK, with bw_in rendered as Mb/s (bw_in is bits/s:
    # 7031032 → 7.0 Mb/s).
    out=$("$helper" status --expected-key restoration <"$xml_full" 2>&1) || true
    case "$out" in
        "OK|Publisher|live/restoration from 192.168.0.108 7.0 Mb/s"*) PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat status emits OK row for matching publisher\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat status wrong row for matching publisher; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat status wrong row for matching publisher\n" ;;
    esac

    # Case 10: status mode flags a wrong-key publisher as WARN and names the
    # key the player expects, so the mismatch is readable on the HDMI screen.
    out=$("$helper" status --expected-key restoration <"$xml_mismatch" 2>&1) || true
    case "$out" in
        "WARN|Publisher|"*"wrongkey"*"player expects restoration"*) PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat status flags wrong-key publisher as WARN\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat status missed wrong-key publisher; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat status missed wrong-key publisher\n" ;;
    esac

    # Case 11: status mode with no publishers → a single OK "none" row (idle
    # splash is normal; the RTMP Stream check separately warns on no-stream).
    out=$("$helper" status --expected-key restoration <"$xml_no_stream" 2>&1) || true
    case "$out" in
        "OK|Publishers|none") PASS=$((PASS + 1))
            printf "${GREEN}  PASS${RESET} parse_stat status reports none when no publishers\n" ;;
        *) FAIL=$((FAIL + 1)); ERRORS+=("parse_stat status wrong output for no publishers; got: $out")
            printf "${RED}  FAIL${RESET} parse_stat status wrong output for no publishers\n" ;;
    esac
}
parse_stat_behavior_test

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

# Pi 5 / Trixie regression 2026-06-13: the kernel video=HDMI-A-1:<mode>
# parameter synthesizes a modeline that diverges from EDID-reported modes
# (e.g. kernel makes "1920x1080@30.00" while panel reports
# "1920x1080@30.003"). KMS ends up on the synthesized mode, wayland (cage)
# on the EDID-preferred mode; every atomic commit fails -> black screen.
# Single source of truth is now HDMI_MODE applied by wlr-randr at
# runtime. setup-kiosk.sh and set-hdmi-mode.sh must STRIP any existing
# video=HDMI-A-1:* token but NEVER add one.
assert_contains "setup-kiosk.sh strips stale video=HDMI-A-1: token (cleanup)" \
    "$REPO_ROOT/install/setup-kiosk.sh" "s/( |^)video=HDMI-A-1:"
assert_not_contains "setup-kiosk.sh does not ADD video=HDMI-A-1: token" \
    "$REPO_ROOT/install/setup-kiosk.sh" 'video=HDMI-A-1:\${HDMI_MODE}'

# Standalone fix-script for an already-deployed Pi
assert_file_exists "dev/set-hdmi-mode.sh exists" "$REPO_ROOT/dev/set-hdmi-mode.sh"
assert_executable  "dev/set-hdmi-mode.sh is executable" "$REPO_ROOT/dev/set-hdmi-mode.sh"
assert_contains "set-hdmi-mode.sh edits cmdline.txt (KMS-correct path)" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" "cmdline.txt"
# config.txt may be *read* (to warn about inert legacy keys) but must never
# be written by this script — the KMS-correct path lives in cmdline.txt.
assert_not_contains "set-hdmi-mode.sh does not write to config.txt (sudo tee/sed -i CONFIG)" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" 'sudo tee.*\$CONFIG\|sed -i.*\$CONFIG\|> *\$CONFIG'
# Same Pi 5 / Trixie reason as setup-kiosk.sh above.
assert_contains "set-hdmi-mode.sh strips stale video=HDMI-A-1: token (cleanup)" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" 'video=HDMI-A-1:'
assert_not_contains "set-hdmi-mode.sh does not ADD video=HDMI-A-1: token" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" 'video=HDMI-A-1:\${MODE}'
assert_contains "set-hdmi-mode.sh validates cmdline.txt is one non-empty line" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" "grep -c"

# `/boot/firmware/cmdline.txt` writes aren't (and shouldn't be) in the deploy
# NOPASSWD list, so the remote `sudo cp/tee` must be able to prompt for a
# password. That requires:
#   1. A PTY on the remote: `ssh -t` (or -tt).
#   2. The remote stdin NOT consumed by the script payload (otherwise the
#      password prompt has nowhere to read from). The script must be sent
#      as a command argument, not via stdin-fed `bash -s <<<…`.
# Captured 2026-05-10: `sudo: a terminal is required to read the password`.
assert_contains "set-hdmi-mode.sh allocates a remote TTY for the sudo prompt" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" "ssh -t"
assert_not_contains "set-hdmi-mode.sh does not feed bash -s via stdin (blocks sudo prompt)" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" 'ssh "\$HOST" "bash -s'

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
echo "=== set-pi-time Tests ==="
# ============================================================================
# `make set-time` pushes the laptop's clock to the Pi over SSH. Primary use
# case: offline venue where systemd-timesyncd has no upstream and the Pi
# (no RTC) has drifted. Optional OFFSET seconds to anticipate SSH round-trip
# lag so the clock lands on the intended wall time.
#
# Same sudo-TTY constraints as set-hdmi-mode.sh: `date -s` is intentionally
# NOT in install/kiosk-deploy.sudoers (rare + root-level → worth a password),
# so the remote sudo must be able to prompt. That requires `ssh -t` AND the
# remote script delivered as a command arg (not via `bash -s <<<…`, which
# closes local stdin and blocks the password prompt).

assert_file_exists "dev/set-pi-time.sh exists" "$REPO_ROOT/dev/set-pi-time.sh"
assert_executable  "dev/set-pi-time.sh is executable" "$REPO_ROOT/dev/set-pi-time.sh"
assert_contains "set-pi-time.sh has shebang" \
    "$REPO_ROOT/dev/set-pi-time.sh" "^#!/bin/bash"
assert_contains "set-pi-time.sh has set -euo pipefail" \
    "$REPO_ROOT/dev/set-pi-time.sh" "^set -euo pipefail"

# Epoch form: timezone-independent. Sending a formatted wall-clock string
# would require the Pi's TZ to match the laptop's; @<epoch> avoids that.
assert_contains "set-pi-time.sh sends epoch (date -s @<seconds>)" \
    "$REPO_ROOT/dev/set-pi-time.sh" 'date -s @'

# Numeric offset validation — reject non-numeric to avoid wedging cmdline.
assert_contains "set-pi-time.sh rejects non-numeric OFFSET" \
    "$REPO_ROOT/dev/set-pi-time.sh" "OFFSET must be numeric"

# Sudo-prompt plumbing (see comment block above).
assert_contains "set-pi-time.sh allocates a remote TTY for the sudo prompt" \
    "$REPO_ROOT/dev/set-pi-time.sh" "ssh -t"
assert_not_contains "set-pi-time.sh does not feed bash -s via stdin (blocks sudo prompt)" \
    "$REPO_ROOT/dev/set-pi-time.sh" 'ssh "\$HOST" "bash -s'

# Behavioral check: the offset arithmetic must produce a sane epoch value.
# Run the (fixed) snippet against a known-now and verify offset is applied.
offset_math_test() {
    local snippet result
    # Extract the line that computes TARGET from EPOCH+OFFSET.
    snippet=$(grep -E '^\s*TARGET=' "$REPO_ROOT/dev/set-pi-time.sh" | head -1)
    if [[ -z "$snippet" ]]; then
        FAIL=$((FAIL + 1)); ERRORS+=("TARGET computation not found in set-pi-time.sh")
        printf "${RED}  FAIL${RESET} TARGET computation snippet present\n"
        return
    fi
    # Feed a fixed EPOCH and known OFFSET; expect EPOCH+OFFSET to within 1us.
    result=$(EPOCH=1700000000.000000 OFFSET=1.5 bash -c "$snippet"$'\necho "$TARGET"')
    if [[ "$result" != "1700000001.500000" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("offset arithmetic: expected 1700000001.500000, got '$result'")
        printf "${RED}  FAIL${RESET} OFFSET=1.5 added to EPOCH (got '%s')\n" "$result"
        return
    fi
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${RESET} OFFSET arithmetic applies seconds correctly\n"
}
offset_math_test

# Behavioral check: non-numeric OFFSET must exit non-zero before touching SSH.
offset_reject_test() {
    local out rc
    out=$("$REPO_ROOT/dev/set-pi-time.sh" displaypi notanumber 2>&1) && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("OFFSET=notanumber should exit non-zero; got rc=0 out='$out'")
        printf "${RED}  FAIL${RESET} non-numeric OFFSET is rejected (exits non-zero)\n"
        return
    fi
    if ! grep -q "OFFSET must be numeric" <<<"$out"; then
        FAIL=$((FAIL + 1))
        ERRORS+=("OFFSET=notanumber: expected error message; got '$out'")
        printf "${RED}  FAIL${RESET} non-numeric OFFSET prints helpful error\n"
        return
    fi
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${RESET} non-numeric OFFSET is rejected with helpful error\n"
}
offset_reject_test

# Makefile exposes the mechanism.
assert_contains "Makefile has set-time target" \
    "$REPO_ROOT/Makefile" "^set-time:"
assert_contains "Makefile set-time target invokes dev/set-pi-time.sh" \
    "$REPO_ROOT/Makefile" "set-pi-time.sh"
assert_contains "Makefile declares TIME_OFFSET variable (default 0)" \
    "$REPO_ROOT/Makefile" "^TIME_OFFSET"
assert_contains "Makefile help mentions set-time" \
    "$REPO_ROOT/Makefile" "set-time "
assert_contains "Makefile .PHONY includes set-time" \
    "$REPO_ROOT/Makefile" '\.PHONY:.* set-time'

# ============================================================================
echo ""
echo "=== Runtime mode enforcement (wlr-randr layer) Tests ==="
# ============================================================================
# Goal: the kernel `video=HDMI-A-1:<mode>` cmdline parameter is a best-effort
# hint that some panels' EDID override. A second authoritative layer runs
# inside the cage session: `wlr-randr --output $HDMI_OUTPUT --mode $HDMI_MODE`
# before mpv launches. The mode string lives in /etc/default/kiosk (sourced
# by kiosk.service via EnvironmentFile=) so both setup-kiosk.sh and
# dev/set-hdmi-mode.sh write the same source of truth.

# kiosk.service pulls in /etc/default/kiosk
assert_contains "kiosk.service sources /etc/default/kiosk (EnvironmentFile)" \
    "$REPO_ROOT/install/kiosk.service" 'EnvironmentFile=-/etc/default/kiosk'

# player.sh calls wlr-randr before mpv to force the active mode
assert_contains "player.sh invokes wlr-randr to enforce HDMI_MODE" \
    "$REPO_ROOT/install/player.sh" "wlr-randr"
assert_contains "player.sh references HDMI_MODE env var" \
    "$REPO_ROOT/install/player.sh" "HDMI_MODE"
assert_contains "player.sh references HDMI_OUTPUT env var (default HDMI-A-1)" \
    "$REPO_ROOT/install/player.sh" "HDMI_OUTPUT"
# Defensive: wlr-randr failures must not abort the player loop — better
# to show the wrong size than not display at all.
assert_contains "player.sh tolerates wlr-randr failure (no hard exit)" \
    "$REPO_ROOT/install/player.sh" 'wlr-randr.*|| '

# setup-kiosk.sh writes /etc/default/kiosk when HDMI_MODE is set
assert_contains "setup-kiosk.sh writes /etc/default/kiosk" \
    "$REPO_ROOT/install/setup-kiosk.sh" '/etc/default/kiosk'
assert_contains "setup-kiosk.sh writes HDMI_MODE= into /etc/default/kiosk" \
    "$REPO_ROOT/install/setup-kiosk.sh" 'HDMI_MODE='
# Apt list must include wlr-randr (cage stack uses it for runtime mode setting)
assert_contains "setup-kiosk.sh installs wlr-randr" \
    "$REPO_ROOT/install/setup-kiosk.sh" 'wlr-randr'

# set-hdmi-mode.sh writes both layers in one shot
assert_contains "set-hdmi-mode.sh writes /etc/default/kiosk (runtime layer)" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" '/etc/default/kiosk'
assert_contains "set-hdmi-mode.sh writes HDMI_MODE= token" \
    "$REPO_ROOT/dev/set-hdmi-mode.sh" 'HDMI_MODE='

# render-status.sh has the new display-mode check
assert_contains "render-status.sh defines check_display_mode" \
    "$REPO_ROOT/diagnostics/render-status.sh" '^check_display_mode()'
assert_contains "render-status.sh check_display_mode invokes wlr-randr" \
    "$REPO_ROOT/diagnostics/render-status.sh" 'wlr-randr'
assert_contains "render-status.sh CHECKS list includes check_display_mode" \
    "$REPO_ROOT/diagnostics/render-status.sh" '    check_display_mode'

# Behavioral test: stub wlr-randr to return a chosen active mode, run
# check_display_mode in isolation, confirm it emits the right status row.
display_mode_check_behavior_test() {
    local tmpdir stub out status
    tmpdir=$(mktemp -d)
    # Stub: print canonical wlr-randr output where the "(current)" mode is
    # 3840x2160 @ 30Hz — the bug we're guarding against.
    cat >"$tmpdir/wlr-randr" <<'EOF'
#!/bin/bash
cat <<'OUT'
HDMI-A-1 "ONN 100012587 (HDMI-A-1)"
  Modes:
    3840x2160 px, 30.000000 Hz (preferred, current)
    1920x1080 px, 60.000000 Hz
    1920x1080 px, 30.000000 Hz
OUT
EOF
    chmod +x "$tmpdir/wlr-randr"

    # Source render-status.sh up to (and including) check_display_mode without
    # running the bottom-of-file render logic. Extract just the function body
    # and call it with the stub on PATH.
    if ! grep -q '^check_display_mode()' "$REPO_ROOT/diagnostics/render-status.sh"; then
        FAIL=$((FAIL + 1))
        ERRORS+=("check_display_mode not yet defined in render-status.sh")
        printf "${RED}  FAIL${RESET} check_display_mode behavior test (function missing)\n"
        rm -rf "$tmpdir"
        return
    fi

    # Extract the function: from "check_display_mode()" through the matching
    # closing brace at column 1. Bash functions in this repo are written one
    # per top-level block, so a simple awk slice works.
    local fn_src
    fn_src=$(awk '
        /^check_display_mode\(\)/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^\}/ { exit }
    ' "$REPO_ROOT/diagnostics/render-status.sh")

    # Mismatch case: HDMI_MODE asks for 1920x1080@30Hz, stub says 3840x2160 — WARN
    out=$(PATH="$tmpdir:$PATH" HDMI_MODE="1920x1080@30Hz" HDMI_OUTPUT="HDMI-A-1" \
        bash -c "$fn_src; check_display_mode" 2>/dev/null)
    status="${out%%|*}"
    if [[ "$status" != "WARN" && "$status" != "FAIL" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("check_display_mode mismatch case: expected WARN/FAIL, got '$status' (full='$out')")
        printf "${RED}  FAIL${RESET} check_display_mode emits WARN when active mode differs from HDMI_MODE (got '%s')\n" "$status"
    else
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} check_display_mode emits %s when active mode differs from HDMI_MODE\n" "$status"
    fi

    # Match case: stub already says 1920x1080@30 is current — flip it
    cat >"$tmpdir/wlr-randr" <<'EOF'
#!/bin/bash
cat <<'OUT'
HDMI-A-1 "ONN 100012587 (HDMI-A-1)"
  Modes:
    3840x2160 px, 30.000000 Hz (preferred)
    1920x1080 px, 60.000000 Hz
    1920x1080 px, 30.000000 Hz (current)
OUT
EOF
    out=$(PATH="$tmpdir:$PATH" HDMI_MODE="1920x1080@30Hz" HDMI_OUTPUT="HDMI-A-1" \
        bash -c "$fn_src; check_display_mode" 2>/dev/null)
    status="${out%%|*}"
    if [[ "$status" != "OK" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("check_display_mode match case: expected OK, got '$status' (full='$out')")
        printf "${RED}  FAIL${RESET} check_display_mode emits OK when active mode matches HDMI_MODE (got '%s')\n" "$status"
    else
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} check_display_mode emits OK when active mode matches HDMI_MODE\n"
    fi

    rm -rf "$tmpdir"
}
display_mode_check_behavior_test

# Behavioral: setup-kiosk.sh /etc/default/kiosk writer should use a marker
# block (consistent with how it brackets config.txt edits) so re-runs replace
# cleanly. Loose check — just that BOTH the marker pattern and the
# /etc/default/kiosk path appear in the same function/block.
assert_contains "setup-kiosk.sh /etc/default/kiosk uses kiosk-setup marker block" \
    "$REPO_ROOT/install/setup-kiosk.sh" 'kiosk-setup BEGIN'

# judder.sh playbook documents the dual-layer mechanism
assert_contains "judder.sh tree mentions /etc/default/kiosk (runtime mode source)" \
    "$REPO_ROOT/diagnostics/judder.sh" '/etc/default/kiosk'
assert_contains "judder.sh tree mentions wlr-randr (runtime enforcement)" \
    "$REPO_ROOT/diagnostics/judder.sh" 'wlr-randr'

# ============================================================================
echo ""
echo "=== SSH splash-bundle removal Tests ==="
# ============================================================================
# The hand-delivered SSH-key splash bundle is gone. It let a volunteer pipe one
# image over SSH to a dedicated `splash-updater` user whose authorized_keys
# ForceCommand routed the bytes through accept-splash into install-staged-splash.
#
# The browser-based web manager (web/kiosk_manager.py) does everything the
# bundle did and more — upload, delete, reorder, restart — behind a token the
# admin can rotate at will. The bundle, by contrast, needed a standing Unix
# user, a NOPASSWD sudoers rule, and a private key copied onto volunteer
# laptops and USB sticks that nobody ever rotated. Its stated reason to exist
# was "works when the web manager isn't reachable", but it needed SSH to the
# same Pi on the same LAN, so it never actually covered that case.
#
# These assertions keep the subsystem from creeping back in. On a Pi that ran
# the old install/splash-updater-setup.sh, the leftovers are removed by hand —
# see the v0.30.0 CHANGELOG entry for the teardown commands.

assert_file_absent "install/accept-splash.sh is gone" \
    "$REPO_ROOT/install/accept-splash.sh"
assert_file_absent "install/install-staged-splash.sh is gone" \
    "$REPO_ROOT/install/install-staged-splash.sh"
assert_file_absent "install/splash-updater-setup.sh is gone" \
    "$REPO_ROOT/install/splash-updater-setup.sh"
assert_file_absent "dev/splash-replace.sh is gone" \
    "$REPO_ROOT/dev/splash-replace.sh"
assert_file_absent "dev/splash-replace.ps1 is gone" \
    "$REPO_ROOT/dev/splash-replace.ps1"
assert_file_absent "docs/admin-splash-update.md is gone" \
    "$REPO_ROOT/docs/admin-splash-update.md"

# splash-store.sh is the one authority on where images live, so its header is
# the first thing a reader trusts — it must not describe a delivery path that
# no longer exists.
assert_not_contains "splash-store.sh header no longer describes the SSH-bundle updater" \
    "$REPO_ROOT/install/splash-store.sh" 'SSH-bundle updater'
assert_not_contains "splash-store.sh no longer references the 00-volunteer drop-in" \
    "$REPO_ROOT/install/splash-store.sh" '00-volunteer'

assert_not_contains "Makefile has no volunteer-bundle target" \
    "$REPO_ROOT/Makefile" '^volunteer-bundle:'
assert_not_contains "Makefile .PHONY drops volunteer-bundle" \
    "$REPO_ROOT/Makefile" '\.PHONY:.* volunteer-bundle'
assert_not_contains "Makefile never pulls the splash-updater private key" \
    "$REPO_ROOT/Makefile" 'splash-updater'
assert_not_contains "Makefile help no longer offers volunteer-bundle" \
    "$REPO_ROOT/Makefile" 'volunteer-bundle'

# The volunteer-facing guide stays — rewritten around the web manager, which
# is now the only way a volunteer changes a slide.
assert_file_exists "docs/volunteer-splash-update.md still exists (web-manager guide)" \
    "$REPO_ROOT/docs/volunteer-splash-update.md"
assert_not_contains "volunteer guide no longer hands out an SSH key" \
    "$REPO_ROOT/docs/volunteer-splash-update.md" 'splash-updater'
assert_not_contains "volunteer guide no longer references the replace scripts" \
    "$REPO_ROOT/docs/volunteer-splash-update.md" 'splash-replace'
assert_contains "volunteer guide points at the web manager" \
    "$REPO_ROOT/docs/volunteer-splash-update.md" 'web manager'

assert_not_contains "README no longer advertises the SSH bundle" \
    "$REPO_ROOT/README.md" 'volunteer-bundle'
assert_not_contains ".gitignore no longer carries bundle artifacts" \
    "$REPO_ROOT/.gitignore" 'volunteer-bundle.zip'
assert_not_contains ".gitignore no longer carries splash-updater keys" \
    "$REPO_ROOT/.gitignore" 'splash-updater'

# ============================================================================
echo ""
echo "=== test-stream preflight Tests ==="
# ============================================================================
# Two misconfigurations make `make test-stream` fail in ways that name neither
# cause:
#
#   1. nginx's `allow publish <cidr>; deny publish all;` drops the connection
#      when the workstation is outside the allow-list. ffmpeg reports only
#      "Broken pipe".
#   2. The stream key the script publishes under differs from the one
#      player.sh watches. nginx accepts any key inside the app, so the publish
#      SUCCEEDS and the display simply never switches — no error at all.
#
# The preflight reads both values off the Pi and refuses to burn 60 seconds on
# a run that cannot work.
TS="$REPO_ROOT/dev/test-stream.sh"

assert_contains "test-stream.sh reads the Pi's publish allow-list" \
    "$TS" 'RTMP_ALLOW_PUBLISH_CIDRS'
assert_contains "test-stream.sh reads the Pi's stream key" \
    "$TS" 'STREAM_KEY'
assert_contains "test-stream.sh determines the workstation's source IP toward the Pi" \
    "$TS" 'ip route get'
assert_contains "test-stream.sh has a cidr_contains helper" \
    "$TS" '^cidr_contains()'
assert_contains "test-stream.sh has an ip_to_int helper" \
    "$TS" '^ip_to_int()'
# An unreachable Pi must degrade the CHECK, not abort the run: ffmpeg may still
# reach an RTMP server this workstation can't SSH into.
assert_contains "test-stream.sh warns rather than dies when the Pi config can't be read" \
    "$TS" 'preflight skipped'

# Behavior test: extract the CIDR helpers and exercise the boundaries. An
# off-by-one in the mask silently authorizes (or blocks) an entire subnet, and
# a static grep cannot see that.
cidr_behavior_test() {
    local fns tmp rc pass=1
    fns=$(sed -n '/^ip_to_int()/,/^}/p;/^cidr_contains()/,/^}/p' "$TS")
    if [[ -z "$fns" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("cidr behavior: helpers not found in test-stream.sh")
        printf "${RED}  FAIL${RESET} cidr_contains behavior (helpers missing)\n"
        return
    fi
    tmp=$(mktemp)
    printf '%s\n' "$fns" > "$tmp"

    # ip / cidr / expected(0=in, 1=out)
    local -a cases=(
        "192.168.0.106 192.168.0.0/24 0"   # the Pi itself — allowed
        "192.168.1.131 192.168.0.0/24 1"   # the workstation — the real failure
        "192.168.0.1   192.168.0.0/24 0"   # first host in range
        "192.168.0.255 192.168.0.0/24 0"   # broadcast address is still in-range
        "192.168.1.0   192.168.0.0/24 1"   # first address past the boundary
        "10.0.0.5      10.0.0.5/32    0"   # single-host CIDR matches
        "10.0.0.6      10.0.0.5/32    1"   # ...and only that host
        "10.0.0.6      10.0.0.5       1"   # bare IP behaves as /32
        "8.8.8.8       0.0.0.0/0      0"   # match-everything
        "172.16.5.9    172.16.0.0/12  0"   # non-octet-aligned mask
        "172.32.5.9    172.16.0.0/12  1"   # ...just outside it
    )
    local c ip cidr want
    for c in "${cases[@]}"; do
        read -r ip cidr want <<<"$c"
        rc=0
        bash -c "source '$tmp'; cidr_contains '$ip' '$cidr'" || rc=$?
        if [[ "$rc" != "$want" ]]; then
            pass=0
            ERRORS+=("cidr_contains $ip in $cidr: expected rc=$want got rc=$rc")
            printf "${RED}  FAIL${RESET} cidr_contains %s in %s (expected %s, got %s)\n" \
                "$ip" "$cidr" "$want" "$rc"
        fi
    done
    rm -f "$tmp"

    if (( pass )); then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} cidr_contains handles %s boundary cases\n" "${#cases[@]}"
    else
        FAIL=$((FAIL + 1))
    fi
}
cidr_behavior_test

# ============================================================================
echo ""
echo "=== Documentation Tests ==="
# ============================================================================
# Provisioning several Pis is the workflow most likely to be done from memory
# at 8am on a Sunday. The guide has to carry the per-site script pattern, not
# just the manual loop, and the three things that actually bite: a re-flashed
# card's new host key, the seed slides a site doesn't want, and the fact that
# the generated shortcut files hold a live token.
GUIDE="$REPO_ROOT/docs/setup-guide.md"

assert_contains "setup-guide documents scripting the per-site provision loop" \
    "$GUIDE" 'Script it'
assert_contains "site-script template fails loudly (half-provisioned Pi is worse than none)" \
    "$GUIDE" 'set -euo pipefail'
assert_contains "site-script template clears the re-flashed card's stale host key" \
    "$GUIDE" 'ssh-keygen -f "\$HOME/.ssh/known_hosts" -R'
assert_contains "site-script template resolves the splash store via splash-store path" \
    "$GUIDE" 'splash-store path'
assert_contains "site-script template stages the volunteer handout files on the Pi" \
    "$GUIDE" 'volunteer-kiosk.webloc'
assert_contains "setup-guide warns the site script must stay out of git" \
    "$GUIDE" '.gitignore'
assert_contains "docs index points at the batch-provisioning section" \
    "$REPO_ROOT/docs/index.html" 'setup-guide.html#batch-provisioning'

# The two test-stream failure modes are the ones an operator hits on a bench
# that isn't the church LAN, and neither error names its cause without the
# preflight. The guide has to say what the preflight is telling them.
assert_contains "troubleshooting covers the test-stream preflight" \
    "$GUIDE" '### .*make test-stream'
assert_contains "troubleshooting explains the publish-ACL refusal" \
    "$GUIDE" 'cannot publish to'
assert_contains "troubleshooting names the Broken pipe symptom the preflight replaces" \
    "$GUIDE" 'Broken pipe'
assert_contains "troubleshooting says to narrow the allow-list again afterwards" \
    "$GUIDE" 'Narrow it again'

# docs/_config.yml excludes dev-journal from the Jekyll build on purpose — the
# notes stay readable as plain Markdown on github.com. A site-relative link to
# one therefore 404s for every visitor to the published guide, while looking
# perfectly fine in the repo. Link to the GitHub blob URL instead.
assert_contains "_config.yml still excludes dev-journal from the site build" \
    "$REPO_ROOT/docs/_config.yml" '^  - dev-journal'
assert_not_contains "setup-guide has no site-relative dev-journal links (they 404 when published)" \
    "$REPO_ROOT/docs/setup-guide.md" '](dev-journal/'

# ============================================================================
echo ""
echo "=== Splash creation Tests ==="
# ============================================================================
#
# create_splash() in setup-kiosk.sh populates the canonical splash store on
# first setup. Source precedence (only when the store holds no images yet):
#   1. repo images/splash.d/*   -> seed the whole rotation set
#   2. repo images/splash.png   -> seed it as the single slide
#   3. other images in images/  -> prompt the operator to pick one
#   4. nothing usable           -> generate a placeholder via ImageMagick
# Everything lands in /var/lib/kiosk-splash; nothing is written to /home/kiosk.
SETUP="$REPO_ROOT/install/setup-kiosk.sh"

assert_contains "create_splash leaves an already-populated store alone" \
    "$SETUP" 'leaving it alone'
assert_contains "create_splash resolves the repo images/ dir from its own path" \
    "$SETUP" 'images_dir='
assert_contains "create_splash seeds the rotation set through splash-store.sh" \
    "$SETUP" 'bash "\$store_helper" seed'
assert_contains "create_splash falls back to the repo images/splash.png" \
    "$SETUP" '${images_dir}/splash.png'
# The source file lives under the SSH user's 0700 home (display-pi-bootstrap/),
# which the kiosk user cannot traverse. Copy AS ROOT via `install` (root reads
# anywhere) and let -o/-g hand the destination to the store's owner atomically.
assert_contains "create_splash installs the chosen splash as root so it can read the bootstrap dir" \
    "$SETUP" 'sudo install -o "\$KIOSK_USER" -g "\$KIOSK_USER" -m 0644'
assert_contains "create_splash prompts to pick when only other images exist" \
    "$SETUP" 'select '
assert_contains "create_splash only prompts on an interactive tty (no CI hang)" \
    "$SETUP" '&& -t 0'
assert_contains "create_splash keeps the ImageMagick placeholder fallback" \
    "$SETUP" 'convert -size 1920x1080'
assert_not_contains "create_splash never writes a splash into /home/kiosk" \
    "$SETUP" '/home/\${KIOSK_USER}/splash'
# The player must be told where the store is through the SAME config file it
# reads at runtime, at STEP 1 — not first written by setup-web at step 3.
assert_contains "setup-kiosk.sh persists SPLASH_DIR to /etc/default/kiosk" \
    "$SETUP" 'set_env_kv "\$KIOSK_ENV_FILE" SPLASH_DIR'
assert_contains "setup-kiosk.sh bootstrap player has the rotation picker" \
    "$SETUP" 'next_splash_image'

# Behavior test: run the real create_splash against a temp store. This is the
# function that decides what a brand-new Pi shows on its very first idle
# period, and it reaches for `sudo`, ImageMagick and the store helper — worth
# exercising rather than grepping. `sudo` and `convert` are stubbed; the
# store helper is the real one.
create_splash_behavior_test() {
    local fn_body tmp inst store got
    fn_body=$(sed -n '/^create_splash()/,/^}/p' "$SETUP")
    if [[ -z "$fn_body" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("create_splash behavior: function not found")
        printf "${RED}  FAIL${RESET} create_splash behavior (function missing)\n"
        return
    fi
    tmp=$(mktemp -d)
    inst="$tmp/install"
    mkdir -p "$inst" "$tmp/images/splash.d" "$tmp/bin"
    cp "$REPO_ROOT/install/splash-store.sh" "$inst/"

    # `sudo` becomes `env`, which handles the VAR=value prefixes create_splash
    # passes and then runs the command unprivileged.
    printf '#!/bin/bash\nexec env "$@"\n' > "$tmp/bin/sudo"
    # `convert` just makes a file, so the placeholder branch is observable
    # without ImageMagick installed on the workstation.
    printf '#!/bin/bash\nprintf "fake-png" > "${!#}"\n' > "$tmp/bin/convert"
    # chown is a no-op off-root.
    printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/chown"
    chmod +x "$tmp/bin"/*

    run_create_splash() {
        local store_dir="$1"
        PATH="$tmp/bin:$PATH" bash -c "
set -euo pipefail
log() { :; }
KIOSK_USER=\"\$(id -un)\"
SPLASH_STORE='$store_dir'
SPLASH_TEXT='Service will begin shortly'
$fn_body
create_splash
" 2>&1
    }

    # 1. Repo ships a rotation set -> the whole set is seeded.
    : > "$tmp/images/splash.d/01-a.png"; : > "$tmp/images/splash.d/02-b.png"
    store="$tmp/store1"
    ( cd "$inst" && run_create_splash "$store" >/dev/null )
    got=$(cd "$store" 2>/dev/null && printf '%s ' * || echo MISSING)
    assert_eq "create_splash seeds the whole rotation set into the store" \
        "01-a.png 02-b.png " "$got"

    # 2. Store already populated -> untouched (an operator's slides survive
    #    a re-run of setup, which is what makes setup-kiosk.sh idempotent).
    echo "operator" > "$store/00-mine.png"
    ( cd "$inst" && run_create_splash "$store" >/dev/null )
    assert_eq "create_splash leaves an already-populated store alone" \
        "operator" "$(cat "$store/00-mine.png")"

    # 3. No rotation set, but images/splash.png exists -> it becomes slide 01.
    rm -rf "$tmp/images/splash.d"
    : > "$tmp/images/splash.png"
    store="$tmp/store2"
    ( cd "$inst" && run_create_splash "$store" >/dev/null )
    if [[ -f "$store/01-splash.png" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} create_splash installs images/splash.png as slide 01\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("create_splash did not install splash.png as 01-splash.png")
        printf "${RED}  FAIL${RESET} create_splash installs images/splash.png as slide 01\n"
    fi

    # 4. Nothing usable -> the generated placeholder, in the store.
    rm -f "$tmp/images/splash.png"
    store="$tmp/store3"
    ( cd "$inst" && run_create_splash "$store" >/dev/null )
    if [[ -f "$store/01-placeholder.png" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} create_splash generates the placeholder into the store\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("create_splash did not generate 01-placeholder.png in the store")
        printf "${RED}  FAIL${RESET} create_splash generates the placeholder into the store\n"
    fi

    # 5. Nothing is ever written to the kiosk user's home.
    if [[ ! -e "$tmp/home" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} create_splash writes no images outside the store\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("create_splash wrote outside the store")
        printf "${RED}  FAIL${RESET} create_splash writes no images outside the store\n"
    fi

    unset -f run_create_splash
    rm -rf "$tmp"
}
create_splash_behavior_test
# The bootstrap player (runs between `make setup` and `make deploy`) is a hand
# copy of install/player.sh and drifts. It must rotate all 5 splash formats
# (matching the canonical player) and read STREAM_URL from /etc/default/kiosk
# (the single config source, commit 8e8b352) rather than baking a literal.
assert_contains "setup-kiosk.sh bootstrap player globs gif slides" \
    "$SETUP" "iname '\*.gif'"
assert_contains "setup-kiosk.sh bootstrap player globs webp slides" \
    "$SETUP" "iname '\*.webp'"
assert_contains "setup-kiosk.sh bootstrap player reads STREAM_URL override (single config source)" \
    "$SETUP" 'STREAM_URL:-'
# Both the bootstrap player glob AND the create_splash source picker must
# offer the new formats — count the gif/webp globs to prove neither was missed.
# Three now: the bootstrap player, the create_splash source picker, and the
# create_splash "is the store already populated" probe.
gif_globs=$(grep -c "iname '\*.gif'" "$SETUP")
if [[ "$gif_globs" -eq 3 ]]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${RESET} setup-kiosk.sh has gif glob in both bootstrap player and create_splash picker\n"
else
    FAIL=$((FAIL + 1))
    ERRORS+=("setup-kiosk.sh gif globs: expected 3, found $gif_globs")
    printf "${RED}  FAIL${RESET} setup-kiosk.sh gif globs (expected 3, found %s)\n" "$gif_globs"
fi

# ============================================================================
echo ""
echo "=== Splash rotation Tests ==="
# ============================================================================
#
# The kiosk rotates through the images in /var/lib/kiosk-splash, advancing one
# image each time the idle splash is (re)entered (NO timer). next_splash_image()
# runs in the parent shell (the $(show_splash) subshell can't carry the cursor)
# and returns the path via the global SPLASH_NEXT, else fails loudly rather
# than showing a blank screen. There is no second image location: the legacy
# SPLASH_IMAGE fallback and the /home/kiosk/splash.d symlink are both gone.
PLAYER="$REPO_ROOT/install/player.sh"
DEPLOY="$REPO_ROOT/dev/deploy.sh"

assert_contains "player.sh defaults SPLASH_DIR to the canonical store" \
    "$PLAYER" 'SPLASH_DIR:-/var/lib/kiosk-splash'
assert_not_contains "player.sh has no legacy single-image fallback" \
    "$PLAYER" 'SPLASH_IMAGE'
assert_contains "player.sh persists the rotation cursor (advances across restarts)" \
    "$PLAYER" 'SPLASH_STATE'
assert_contains "player.sh has a next_splash_image picker" \
    "$PLAYER" '^next_splash_image()'
assert_contains "player.sh enumerates the folder deterministically" \
    "$PLAYER" 'sort -z'
assert_contains "player.sh show_splash takes the image as an argument" \
    "$PLAYER" '"\$1" </dev/null'
assert_contains "player.sh still holds a single splash forever (no flicker)" \
    "$PLAYER" 'image-display-duration=inf'
assert_contains "player.sh errors loudly when no splash is available" \
    "$PLAYER" 'no splash image'
assert_contains "player.sh guards kill/wait against an empty splash PID" \
    "$PLAYER" '\-n "\$SPLASH_PID"'

# Images live in exactly ONE place on the Pi: /var/lib/kiosk-splash. Deploy no
# longer symlinks anything into /home/kiosk — that symlink pointed at the repo
# working tree, which the player stopped reading the moment setup-web wrote
# SPLASH_DIR into /etc/default/kiosk, so repo images silently diverged from
# what was on screen. Deploy now migrates any legacy content into the store and
# seeds it through the same splash-store.sh helper setup-web uses.
assert_not_contains "deploy.sh no longer symlinks splash.d into /home/kiosk" \
    "$DEPLOY" 'ln -sfn .*images/splash.d'
assert_not_contains "deploy.sh no longer symlinks splash.png into /home/kiosk" \
    "$DEPLOY" 'ln -sf .*images/splash.png'
assert_not_contains "deploy.sh no longer copies splash images by hand" \
    "$DEPLOY" 'cp .*images/splash'
assert_contains "deploy.sh seeds the splash store via the shared helper" \
    "$DEPLOY" 'splash-store.sh seed'
assert_contains "deploy.sh migrates legacy /home/kiosk splash paths" \
    "$DEPLOY" 'splash-store.sh migrate'
# The rsync --delete exclusion for *-volunteer.* is gone. It protected an
# upload that landed at images/splash.d/00-volunteer.png back when
# /home/kiosk/splash.d symlinked into the repo working tree — i.e. inside the
# rsync destination. Since the store moved to /var/lib/kiosk-splash it sits
# outside REMOTE_DIR entirely, so --delete cannot reach a slide there and the
# exclusion guarded nothing while implying deploy still had to.
assert_not_contains "deploy.sh has no vestigial *-volunteer.* --delete exclusion" \
    "$DEPLOY" "exclude='\\*-volunteer\\.\\*'"

assert_file_exists "repo ships a splash.d rotation folder (seed image)" \
    "$REPO_ROOT/images/splash.d/01-rcc.png"

# Behavior test: extract next_splash_image and exercise it against temp dirs.
# Same pattern as nearest_refresh_behavior_test above.
next_splash_behavior_test() {
    local fn_body
    fn_body=$(sed -n '/^next_splash_image()/,/^}/p' "$PLAYER")
    if [[ -z "$fn_body" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("next_splash_image behavior: function not found")
        printf "${RED}  FAIL${RESET} next_splash_image behavior (function missing)\n"
        return
    fi
    local tmpdir emptydir got want fallback rc statefile one
    tmpdir=$(mktemp -d)
    : > "$tmpdir/01-a.png"; : > "$tmpdir/02-b.png"; : > "$tmpdir/03-c.png"
    statefile="$tmpdir/idx"

    # Cursor persists to a state file: four SEPARATE invocations (each a fresh
    # process, like a service restart) cycle A,B,C,A in filename order. This is
    # the behavior `make restart` relies on.
    got=""
    for i in 1 2 3 4; do
        one=$(bash -c "$fn_body
SPLASH_DIR='$tmpdir'; SPLASH_STATE='$statefile'
next_splash_image && basename \"\$SPLASH_NEXT\"" || true)
        got+="$one"$'\n'
    done
    got="${got%$'\n'}"
    want=$'01-a.png\n02-b.png\n03-c.png\n01-a.png'
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} next_splash_image cycles images A,B,C,A\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("next_splash_image cycle: want '$want' got '$got'")
        printf "${RED}  FAIL${RESET} next_splash_image cycles A,B,C,A (got: %s)\n" "${got//$'\n'/,}"
    fi

    # SPLASH_DIR may still be reached through a symlink (an operator pointing
    # /var/lib/kiosk-splash at external storage). `find` must follow the
    # starting symlink (-L) or it sees an empty dir and never rotates.
    local linkdir
    linkdir=$(mktemp -d)/link
    ln -sfn "$tmpdir" "$linkdir"
    got=$(bash -c "$fn_body
SPLASH_DIR='$linkdir'; SPLASH_STATE='$linkdir.idx'
next_splash_image && basename \"\$SPLASH_NEXT\"" || true)
    if [[ "$got" == "01-a.png" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} next_splash_image follows a symlinked splash dir\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("next_splash_image symlinked dir: want '01-a.png' got '$got'")
        printf "${RED}  FAIL${RESET} next_splash_image follows a symlinked splash dir (got: %s)\n" "$got"
    fi
    rm -rf "$(dirname "$linkdir")"

    # An empty store is a hard failure now — there is no second location to
    # fall back to, so the caller must surface it loudly rather than silently
    # showing nothing. (The store is seeded at setup and never emptied by us.)
    emptydir=$(mktemp -d)
    bash -c "$fn_body
SPLASH_DIR='$emptydir'; SPLASH_STATE='$tmpdir/idx2'
next_splash_image" >/dev/null 2>&1 && rc=0 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} next_splash_image fails on an empty store (no hidden fallback)\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("next_splash_image empty store: expected non-zero exit, got 0")
        printf "${RED}  FAIL${RESET} next_splash_image fails on an empty store\n"
    fi

    # A missing store dir entirely -> also non-zero, not a crash under set -u.
    bash -c "$fn_body
SPLASH_DIR='$emptydir/gone'; SPLASH_STATE='$tmpdir/idx3'
next_splash_image" >/dev/null 2>&1 && rc=0 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} next_splash_image returns non-zero when the store dir is missing\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("next_splash_image missing dir: expected non-zero exit, got 0")
        printf "${RED}  FAIL${RESET} next_splash_image returns non-zero when the store dir is missing\n"
    fi

    rm -rf "$tmpdir" "$emptydir"
}
next_splash_behavior_test

# ============================================================================
echo ""
echo "=== Splash store single-location Tests ==="
# ============================================================================
#
# One folder holds the kiosk's images: /var/lib/kiosk-splash. install/
# splash-store.sh is the single implementation of "where is it / make it /
# seed it / migrate into it", shared by setup-kiosk.sh (step 1), deploy.sh
# (step 2) and kiosk-web-setup.sh (step 3) so the three steps cannot drift.
#
# The bug this replaces: deploy symlinked /home/kiosk/splash.d at the repo
# working tree while setup-web pointed SPLASH_DIR at /var/lib/kiosk-splash and
# seeded it once. Two folders, one of them unread, silently diverging.
STORE="$REPO_ROOT/install/splash-store.sh"
WEBSETUP="$REPO_ROOT/install/kiosk-web-setup.sh"

assert_contains "splash-store.sh defines the canonical store path" \
    "$STORE" 'SPLASH_STORE_DEFAULT=/var/lib/kiosk-splash'
assert_contains "splash-store.sh reads the live SPLASH_DIR from the config store" \
    "$STORE" 'KIOSK_ENV_FILE'
assert_contains "splash-store.sh seeds only when the store holds no images" \
    "$STORE" 'store_has_images'
assert_contains "splash-store.sh chowns only when it is actually root" \
    "$STORE" 'EUID -eq 0'

# All three provisioning steps must go through the helper — no hand-rolled
# copy loops, no second opinion about the path.
assert_contains "kiosk-web-setup.sh seeds through the shared helper" \
    "$WEBSETUP" 'splash-store.sh" seed'
assert_not_contains "kiosk-web-setup.sh has no hand-rolled seeding loop" \
    "$WEBSETUP" 'Seeding \$SPLASH_DIR with images from repo'
assert_contains "setup-kiosk.sh seeds through the shared helper" \
    "$SETUP" 'splash-store.sh'

# No shipped code may still WRITE TO or READ FROM the retired /home/kiosk
# locations. Two references are legitimate and excluded: comments explaining
# the old layout, and the `splash-store.sh migrate` call that exists precisely
# to clean those paths up on an already-deployed Pi.
retired_hits=$(grep -rn '/home/kiosk/splash\.d\|/home/kiosk/splash\.png\|/home/\${KIOSK_USER}/splash\.d\|/home/\${KIOSK_USER}/splash\.png' \
    "$REPO_ROOT/install" "$REPO_ROOT/dev" "$REPO_ROOT/web" "$REPO_ROOT/diagnostics" 2>/dev/null \
    | grep -v ':[[:space:]]*#' \
    | grep -v 'splash-store.sh migrate' \
    | grep -v '^[^:]*splash-store\.sh:' \
    | cut -d: -f1 | sort -u || true)
if [[ -z "$retired_hits" ]]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${RESET} no shipped script references the retired /home/kiosk splash paths\n"
else
    FAIL=$((FAIL + 1))
    ERRORS+=("retired splash paths still referenced in: $(echo "$retired_hits" | tr '\n' ' ')")
    printf "${RED}  FAIL${RESET} retired /home/kiosk splash paths still referenced (%s)\n" \
        "$(echo "$retired_hits" | tr '\n' ' ')"
fi

# Behavior tests — run the real helper against temp dirs as an unprivileged
# user. Chown/ownership steps self-skip off-root; everything else is exercised.
splash_store_behavior_test() {
    local tmp env_file store src got
    tmp=$(mktemp -d)
    env_file="$tmp/default-kiosk"
    store="$tmp/store"
    src="$tmp/repo-images"
    mkdir -p "$src"
    : > "$src/01-a.png"; : > "$src/02-b.jpg"; : > "$src/README.md"

    # 1. Path resolution: default when the config store says nothing...
    got=$(KIOSK_ENV_FILE="$env_file" bash "$STORE" path)
    assert_eq "splash-store path falls back to /var/lib/kiosk-splash" \
        "/var/lib/kiosk-splash" "$got"

    # ...and the persisted value when it does. This is the rule that made the
    # old layout unreadable: the live config, not the repo default, wins.
    echo "SPLASH_DIR=$store" > "$env_file"
    got=$(KIOSK_ENV_FILE="$env_file" bash "$STORE" path)
    assert_eq "splash-store path honors SPLASH_DIR from the config store" \
        "$store" "$got"

    # 2. Seeding an empty store copies the images (and nothing else).
    KIOSK_ENV_FILE="$env_file" bash "$STORE" seed "$src" >/dev/null
    got=$(cd "$store" && printf '%s ' *)
    assert_eq "splash-store seed copies only image files into an empty store" \
        "01-a.png 02-b.jpg " "$got"

    # 3. Seeding again is a no-op — a populated store is operator/volunteer
    #    territory and the repo never overwrites it.
    : > "$src/03-c.png"
    echo "volunteer" > "$store/00-volunteer.png"
    KIOSK_ENV_FILE="$env_file" bash "$STORE" seed "$src" >/dev/null
    got=$(cd "$store" && printf '%s ' *)
    assert_eq "splash-store seed is a no-op on a populated store" \
        "00-volunteer.png 01-a.png 02-b.jpg " "$got"
    assert_eq "splash-store seed never clobbers a volunteer slide" \
        "volunteer" "$(cat "$store/00-volunteer.png")"

    # 4. Migration: a REAL legacy folder's images move into the store and the
    #    legacy paths disappear. This is what an existing Pi hits on its first
    #    deploy after the layout change.
    local legacy_dir legacy_img mstore
    legacy_dir="$tmp/legacy.d"; legacy_img="$tmp/legacy.png"
    mstore="$tmp/mstore"
    mkdir -p "$legacy_dir"
    echo "kept" > "$legacy_dir/00-volunteer.png"
    : > "$legacy_img"
    echo "SPLASH_DIR=$mstore" > "$env_file"
    KIOSK_ENV_FILE="$env_file" bash "$STORE" migrate "$legacy_dir" "$legacy_img" >/dev/null
    assert_eq "splash-store migrate moves legacy rotation images into the store" \
        "kept" "$(cat "$mstore/00-volunteer.png" 2>/dev/null)"
    if [[ ! -e "$legacy_dir" && ! -e "$legacy_img" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} splash-store migrate removes the legacy /home/kiosk paths\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("splash-store migrate left legacy paths behind")
        printf "${RED}  FAIL${RESET} splash-store migrate removes the legacy paths\n"
    fi

    # 5. A legacy SYMLINK (the layout deploy.sh actually created) is unlinked,
    #    never followed — deleting through it would eat the repo working tree.
    local link_target linkpath
    link_target="$tmp/repo-splash-d"; linkpath="$tmp/legacy-link"
    mkdir -p "$link_target"; : > "$link_target/01-repo.png"
    ln -sfn "$link_target" "$linkpath"
    KIOSK_ENV_FILE="$env_file" bash "$STORE" migrate "$linkpath" "$tmp/absent.png" >/dev/null
    if [[ ! -e "$linkpath" && -f "$link_target/01-repo.png" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} splash-store migrate unlinks a legacy symlink without touching its target\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("splash-store migrate mishandled a legacy symlink")
        printf "${RED}  FAIL${RESET} splash-store migrate unlinks a legacy symlink safely\n"
    fi

    rm -rf "$tmp"
}
splash_store_behavior_test

# ============================================================================
echo ""
echo "=== become-kiosk-web Tests ==="
# ============================================================================
#
# /var/lib/kiosk-splash is owned by kiosk-web, a --system user with
# /usr/sbin/nologin. `sudo -u kiosk-web -i` therefore fails outright ("This
# account is currently not available"), which is exactly the wall a volunteer
# hits when told to "go look at the splash folder". become-kiosk-web hands
# them a shell as that user, already sitting in the store.
BECOME_WEB="$REPO_ROOT/install/become-kiosk-web.sh"

assert_contains "become-kiosk-web targets the kiosk-web user" \
    "$BECOME_WEB" 'WEB_USER="\${WEB_USER:-kiosk-web}"'
assert_contains "become-kiosk-web invokes an explicit shell (nologin blocks sudo -i)" \
    "$BECOME_WEB" 'sudo -u "\$WEB_USER"'
assert_not_contains "become-kiosk-web does not use 'sudo -i' (would hit nologin)" \
    "$BECOME_WEB" 'sudo -u "\$WEB_USER" -i'
assert_contains "become-kiosk-web starts the operator inside the splash store" \
    "$BECOME_WEB" 'cd "\$SPLASH_DIR"'
assert_contains "become-kiosk-web resolves the store via splash-store.sh" \
    "$BECOME_WEB" 'splash-store.sh'
assert_contains "become-kiosk-web fails clearly when kiosk-web is not installed" \
    "$BECOME_WEB" 'does not exist'
assert_contains "setup-kiosk.sh installs the become-kiosk-web helper" \
    "$SETUP" 'become-kiosk-web'

# ============================================================================
echo ""
echo "=== kiosk-config editor Tests ==="
# ============================================================================
#
# /etc/default/kiosk is the single config store (stream key, RTMP app, HDMI
# mode, SPLASH_DIR). Editing it by hand means sudo + an editor + hoping the
# file still parses; a bad line there breaks kiosk.service's EnvironmentFile
# at next boot. kiosk-config edits a copy, refuses to install anything the
# shell cannot source, and only then replaces the real file.
CONFIG_EDIT="$REPO_ROOT/install/kiosk-config.sh"

assert_contains "kiosk-config edits /etc/default/kiosk" \
    "$CONFIG_EDIT" '/etc/default/kiosk'
assert_contains "kiosk-config prefers micro when no EDITOR is set" \
    "$CONFIG_EDIT" 'micro'
assert_contains "kiosk-config falls back to vim" \
    "$CONFIG_EDIT" 'vim'
assert_contains "kiosk-config validates the edited file before installing it" \
    "$CONFIG_EDIT" 'bash -n'
assert_contains "kiosk-config installs the config 0644 root:root" \
    "$CONFIG_EDIT" 'install -m 0644 -o root -g root'
assert_contains "setup-kiosk.sh installs the kiosk-config helper" \
    "$SETUP" 'kiosk-config'
assert_contains "setup-kiosk.sh installs micro so the editor exists on a fresh Pi" \
    "$SETUP" '^ *micro'
assert_contains "Makefile has a config target" \
    "$REPO_ROOT/Makefile" '^config:'

# Behavior tests — drive the real script with stub editors on PATH.
kiosk_config_behavior_test() {
    local tmp env_file bin rc
    tmp=$(mktemp -d)
    env_file="$tmp/default-kiosk"
    bin="$tmp/bin"
    mkdir -p "$bin"
    printf 'STREAM_KEY=original\nRTMP_APP=live\n' > "$env_file"

    # A well-behaved editor: its change is validated and installed.
    printf '#!/bin/bash\nprintf "VOLUME=55\\n" >> "$1"\n' > "$bin/goodedit"
    # A destructive one: leaves the file unsourceable.
    printf '#!/bin/bash\nprintf "this is ) not shell\\n" >> "$1"\n' > "$bin/bademit"
    # Stand-ins for the real editors, to prove the preference order.
    printf '#!/bin/bash\nprintf "EDITED_BY=micro\\n" >> "$1"\n' > "$bin/micro"
    printf '#!/bin/bash\nprintf "EDITED_BY=nano\\n" >> "$1"\n' > "$bin/nano"
    chmod +x "$bin"/*

    VISUAL= KIOSK_ENV_FILE="$env_file" EDITOR="$bin/goodedit" bash "$CONFIG_EDIT" >/dev/null 2>&1
    assert_contains "kiosk-config applies a valid edit" "$env_file" '^VOLUME=55$'

    VISUAL= KIOSK_ENV_FILE="$env_file" EDITOR="$bin/bademit" bash "$CONFIG_EDIT" >/dev/null 2>&1 && rc=0 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} kiosk-config exits non-zero on an unsourceable edit\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("kiosk-config accepted a broken config (exit 0)")
        printf "${RED}  FAIL${RESET} kiosk-config exits non-zero on an unsourceable edit\n"
    fi
    assert_not_contains "kiosk-config does not install a config the shell cannot source" \
        "$env_file" 'not shell'
    assert_contains "kiosk-config leaves the previous config intact after a rejected edit" \
        "$env_file" '^VOLUME=55$'

    # EDITOR=nano is overridden, not obeyed: micro gets the edit instead.
    PATH="$bin:$PATH" VISUAL= KIOSK_ENV_FILE="$env_file" EDITOR=nano bash "$CONFIG_EDIT" >/dev/null 2>&1
    assert_contains "kiosk-config substitutes micro when EDITOR is nano" \
        "$env_file" '^EDITED_BY=micro$'
    assert_not_contains "kiosk-config never lets nano touch the config" \
        "$env_file" '^EDITED_BY=nano$'

    rm -rf "$tmp"
}
kiosk_config_behavior_test

# ============================================================================
echo ""
echo "=== SSH Password Toggle Tests ==="
# ============================================================================

TOGGLE="$REPO_ROOT/install/sshd-password-toggle.sh"

assert_file_exists "install/sshd-password-toggle.sh exists" "$TOGGLE"
assert_executable  "install/sshd-password-toggle.sh is executable" "$TOGGLE"
assert_contains "sshd-password-toggle.sh has shebang" "$TOGGLE" "^#!/bin/bash"
assert_contains "sshd-password-toggle.sh has set -euo pipefail" "$TOGGLE" "^set -euo pipefail"

# Drop-in must sort first (00-) so it wins sshd's first-value-wins resolution
# over later drop-ins (e.g. rpi-imager's key-only file) and the stock config.
assert_contains "toggle writes a 00- drop-in (sorts first, overrides others)" \
    "$TOGGLE" "sshd_config.d/00-display-pi-auth.conf"

# Pubkey auth is ALWAYS forced on, so STATE=off can't lock out key logins.
assert_contains "toggle always keeps PubkeyAuthentication yes" \
    "$TOGGLE" "PubkeyAuthentication yes"
assert_contains "toggle manages PasswordAuthentication" \
    "$TOGGLE" "PasswordAuthentication"
# Root must never be reachable over SSH regardless of password state — the
# drop-in sorts first so this wins over the stock config / base image.
assert_contains "toggle pins PermitRootLogin no" \
    "$TOGGLE" "PermitRootLogin no"

# Validate before applying; reload (not restart) so the live session survives.
assert_contains "toggle validates config with sshd -t before applying" \
    "$TOGGLE" "sshd -t"
assert_contains "toggle reloads (not restarts) sshd to keep sessions alive" \
    "$TOGGLE" "systemctl reload"
assert_not_contains "toggle never restarts ssh (would drop the live session)" \
    "$TOGGLE" "systemctl restart ssh"

# status reads the effective, resolved config — the real source of truth.
assert_contains "toggle status reads effective config via sshd -T" \
    "$TOGGLE" "sshd -T"

# Regression: a RETURN trap is global and re-fires on every later function
# return. With a deferred ('$tmp') temp-file cleanup that tripped
# `set -u: tmp: unbound variable` once main() returned. Use explicit cleanup.
assert_not_contains "toggle avoids global RETURN trap (set -u unbound-var footgun)" \
    "$TOGGLE" "RETURN"
assert_contains "toggle cleans up its temp file explicitly" \
    "$TOGGLE" 'rm -f "\$tmp"'

# Handles on/off/status, requires root for mutations.
assert_contains "toggle handles on|off|status" "$TOGGLE" "on|off"
assert_contains "toggle requires root to change config" "$TOGGLE" 'EUID'

# Makefile wrapper for easy invocation from the workstation.
assert_contains "Makefile has ssh-password target" "$REPO_ROOT/Makefile" "^ssh-password:"
assert_contains "Makefile ssh-password runs the toggle on the Pi" \
    "$REPO_ROOT/Makefile" "sshd-password-toggle.sh"
assert_contains "Makefile declares ssh-password .PHONY" "$REPO_ROOT/Makefile" "ssh-password"

# Fresh-Pi setup prefers key-only auth, but only when the deploy user already
# has an authorized_keys entry — otherwise it keeps password auth on so a Pi
# imaged without a key can't lock the operator out. Both branches exist.
assert_contains "setup-kiosk.sh wires in SSH auth config" \
    "$REPO_ROOT/install/setup-kiosk.sh" "configure_ssh_auth"
assert_contains "setup-kiosk.sh checks for an installed pubkey before choosing" \
    "$REPO_ROOT/install/setup-kiosk.sh" "authorized_keys"
assert_contains "setup-kiosk.sh flips to key-only when a key is present" \
    "$REPO_ROOT/install/setup-kiosk.sh" 'bash "\$src" off'
assert_contains "setup-kiosk.sh keeps password auth as the no-key fallback" \
    "$REPO_ROOT/install/setup-kiosk.sh" 'bash "\$src" on'

# ============================================================================
echo ""
echo "=== Provision Aggregate Target Tests ==="
# ============================================================================
# `make provision` is the one-command new-kiosk flow. It must drive the four
# one-time steps in strict order: setup → deploy → setup-web → volunteer-web-url.
# A fresh Pi has no canonical /home/kiosk/display-pi until `deploy` runs, and
# `setup-web` reads its install script from that path — so the order is load-
# bearing, not cosmetic. Each step is invoked via a recursive $(MAKE) so the
# ordering survives even under `make -j`.
assert_contains "Makefile has provision target" \
    "$REPO_ROOT/Makefile" "^provision:"
assert_contains "provision runs setup (step 1)" \
    "$REPO_ROOT/Makefile" "(MAKE) setup$"
assert_contains "provision runs deploy (step 2)" \
    "$REPO_ROOT/Makefile" "(MAKE) deploy"
assert_contains "provision runs setup-web (step 3)" \
    "$REPO_ROOT/Makefile" "(MAKE) setup-web"
assert_contains "provision runs volunteer-web-url (step 4)" \
    "$REPO_ROOT/Makefile" "(MAKE) volunteer-web-url"
assert_contains "Makefile .PHONY includes provision" \
    "$REPO_ROOT/Makefile" '\.PHONY:.* provision'
assert_contains "Makefile help mentions provision" \
    "$REPO_ROOT/Makefile" "provision "

# ============================================================================
echo ""
echo "=== Consistency Tests ==="
# ============================================================================

# Stream URL should be consistent across files
assert_contains "player.sh uses restoration stream key" "$REPO_ROOT/install/player.sh" "restoration"
assert_contains "test-stream.sh defaults to restoration" "$REPO_ROOT/dev/test-stream.sh" "restoration"

# Splash path should be consistent — one location, everywhere.
assert_contains "player.sh references the canonical splash store" \
    "$REPO_ROOT/install/player.sh" "/var/lib/kiosk-splash"

# pix_fmt yuv420p in test stream (gotcha #6)
assert_contains "test-stream.sh uses yuv420p" "$REPO_ROOT/dev/test-stream.sh" "yuv420p"

# ============================================================================
echo ""
echo "=== Stream Config Single-Source Tests ==="
# ============================================================================
# The 2026-07-05 provision failure: setup-kiosk.sh baked STREAM_KEY into a
# generated /home/kiosk/bin/player.sh, then `make deploy` (provision step 2)
# replaced that file with a symlink to the repo's install/player.sh, which
# hardcoded the default key — so a custom STREAM_KEY never survived provision.
# The fix: /etc/default/kiosk is the ONE persistent config store. setup writes
# STREAM_URL/STREAM_KEY/RTMP_APP/VOLUME there; kiosk.service loads it via
# EnvironmentFile; player.sh and the diagnostics honor the env override and
# fall back to reading the file when run outside the service (ssh, cron).

SETUP="$REPO_ROOT/install/setup-kiosk.sh"

# player.sh must take STREAM_URL from the environment, not hardcode it.
assert_contains "player.sh stream URL is env-overridable (EnvironmentFile wins)" \
    "$PLAYER" 'STREAM_URL:-rtmp://127\.0\.0\.1/live/restoration'
assert_not_contains "player.sh no longer hardcodes STREAM_URL" \
    "$PLAYER" '^STREAM_URL="rtmp'
assert_contains "player.sh volume is env-overridable (PLAYBACK_VOLUME survives deploy)" \
    "$PLAYER" 'VOLUME:-80'
assert_not_contains "player.sh no longer hardcodes VOLUME" \
    "$PLAYER" '^VOLUME=80'
assert_contains "player.sh falls back to /etc/default/kiosk outside the service" \
    "$PLAYER" '/etc/default/kiosk'

# setup-kiosk.sh persists the stream config to /etc/default/kiosk.
assert_contains "setup-kiosk.sh has a set_env_kv helper" "$SETUP" '^set_env_kv()'
assert_contains "setup-kiosk.sh has configure_stream_config" "$SETUP" '^configure_stream_config()'
assert_contains "setup-kiosk.sh main() calls configure_stream_config" \
    "$SETUP" '^    configure_stream_config'
assert_contains "setup-kiosk.sh persists STREAM_URL" "$SETUP" 'set_env_kv .* STREAM_URL'
assert_contains "setup-kiosk.sh persists STREAM_KEY" "$SETUP" 'set_env_kv .* STREAM_KEY'
assert_contains "setup-kiosk.sh persists RTMP_APP" "$SETUP" 'set_env_kv .* RTMP_APP'
assert_contains "setup-kiosk.sh persists VOLUME" "$SETUP" 'set_env_kv .* VOLUME'
assert_contains "setup-kiosk.sh persists RTMP_ALLOW_PUBLISH_CIDRS" \
    "$SETUP" 'set_env_kv .* RTMP_ALLOW_PUBLISH_CIDRS'

# On an already-deployed Pi /home/kiosk/bin/player.sh is a symlink into the
# repo; the bootstrap generator must replace the link, not write through it
# (tee follows symlinks — that would clobber the deployed repo copy).
assert_contains "setup-kiosk.sh bootstrap player replaces a deploy symlink" \
    "$SETUP" '\-L "\$player_script"'

# Re-running setup without an explicit override keeps the persisted value
# (no silent reset to 'restoration' on a later `make setup HDMI_MODE=…`).
assert_contains "setup-kiosk.sh reads persisted values as defaults" \
    "$SETUP" '^persisted_default()'
assert_contains "Makefile forwards only explicitly-set setup vars (origin check)" \
    "$REPO_ROOT/Makefile" 'origin'

# Diagnostics honor the same store when run standalone (ssh/cron have no
# EnvironmentFile), so what they report is what the player actually uses.
assert_contains "render-status.sh falls back to /etc/default/kiosk" \
    "$REPO_ROOT/diagnostics/render-status.sh" '/etc/default/kiosk'
assert_contains "judder.sh falls back to /etc/default/kiosk" \
    "$REPO_ROOT/diagnostics/judder.sh" '/etc/default/kiosk'

# Behavior: set_env_kv creates, appends, and updates KEY=value lines without
# touching neighbors. sudo is stubbed to a no-op wrapper for the test.
set_env_kv_behavior_test() {
    local fn_body
    fn_body=$(sed -n '/^set_env_kv()/,/^}/p' "$SETUP")
    if [[ -z "$fn_body" ]]; then
        FAIL=$((FAIL + 1))
        ERRORS+=("set_env_kv behavior: function not found")
        printf "${RED}  FAIL${RESET} set_env_kv behavior (function missing)\n"
        return
    fi
    local tmpf got
    tmpf=$(mktemp)
    echo "SPLASH_DIR=/var/lib/kiosk-splash" > "$tmpf"
    got=$(bash -c "sudo() { \"\$@\"; }
$fn_body
set_env_kv '$tmpf' STREAM_URL 'rtmp://127.0.0.1/live/aaa'
set_env_kv '$tmpf' STREAM_URL 'rtmp://127.0.0.1/live/bbb'
set_env_kv '$tmpf' VOLUME 80
cat '$tmpf'")
    rm -f "$tmpf"
    local want=$'SPLASH_DIR=/var/lib/kiosk-splash\nSTREAM_URL=rtmp://127.0.0.1/live/bbb\nVOLUME=80'
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} set_env_kv appends, updates in place, preserves neighbors\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("set_env_kv behavior: want '$want' got '$got'")
        printf "${RED}  FAIL${RESET} set_env_kv behavior (got: %s)\n" "${got//$'\n'/,}"
    fi
}
set_env_kv_behavior_test

# ============================================================================
echo ""
echo "=== nginx.conf Single-Source Render Tests ==="
# ============================================================================
# deploy.sh used to overwrite /etc/nginx/nginx.conf with the repo's static
# copy, reverting any RTMP_APP / allow-publish CIDRs that setup-kiosk.sh had
# generated (and setup's heredoc copy lacked idle_streams/drop_idle_publisher/
# the kiosk-web include — two diverging sources of truth). Both paths now
# render install/nginx.conf through render-nginx-conf.sh with values from
# /etc/default/kiosk, so a deploy can never clobber configured values.

RENDER="$REPO_ROOT/install/render-nginx-conf.sh"
assert_file_exists "install/render-nginx-conf.sh exists" "$RENDER"
assert_executable  "install/render-nginx-conf.sh is executable" "$RENDER"
assert_contains "setup-kiosk.sh renders nginx.conf via render-nginx-conf.sh" \
    "$SETUP" 'render-nginx-conf.sh'
assert_not_contains "setup-kiosk.sh no longer heredocs its own nginx.conf" \
    "$SETUP" 'sudo tee /etc/nginx/nginx.conf'
assert_contains "deploy.sh renders nginx.conf via render-nginx-conf.sh" \
    "$DEPLOY" 'render-nginx-conf.sh'
assert_not_contains "deploy.sh no longer raw-copies nginx.conf (clobbered custom app/CIDRs)" \
    "$DEPLOY" 'cp \${REMOTE_DIR}/install/nginx.conf'

# Behavior: rendering with explicit values substitutes app + CIDRs and keeps
# the template's operational directives; rendering with the template defaults
# reproduces the template byte-for-byte (no drift between the two sources).
render_nginx_behavior_test() {
    local out
    out=$(RTMP_APP=customapp RTMP_ALLOW_PUBLISH_CIDRS='192.168.9.0/24 172.16.0.0/12' \
        KIOSK_ENV_FILE=/nonexistent "$RENDER" "$REPO_ROOT/install/nginx.conf" 2>/dev/null) || out=""
    local ok=1
    grep -q 'application customapp {' <<<"$out" || ok=0
    grep -q 'allow publish 192.168.9.0/24;' <<<"$out" || ok=0
    grep -q 'allow publish 172.16.0.0/12;' <<<"$out" || ok=0
    grep -q 'allow publish 192.168.0.0/16;' <<<"$out" && ok=0
    grep -q 'idle_streams off;' <<<"$out" || ok=0
    grep -q 'kiosk-web-site.d' <<<"$out" || ok=0
    if [[ $ok -eq 1 ]]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} render-nginx-conf.sh substitutes app + CIDRs, keeps directives\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("render-nginx-conf.sh substitution failed")
        printf "${RED}  FAIL${RESET} render-nginx-conf.sh substitution\n"
    fi
    if diff -q <(KIOSK_ENV_FILE=/nonexistent "$RENDER" "$REPO_ROOT/install/nginx.conf" 2>/dev/null) \
        "$REPO_ROOT/install/nginx.conf" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${RESET} render-nginx-conf.sh with defaults reproduces the template exactly\n"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("render-nginx-conf.sh default render != template")
        printf "${RED}  FAIL${RESET} render-nginx-conf.sh default render != template\n"
    fi
}
render_nginx_behavior_test

# ============================================================================
echo ""
echo "=== Static IP Gateway/DNS Tests ==="
# ============================================================================
# STATIC_IP is an extra direct-reach address (no gateway) by design. For the
# "this is the Pi's primary address" case, STATIC_GATEWAY/STATIC_DNS are now
# plumbed through so the profile can carry a real default route + resolver.
assert_contains "setup-kiosk.sh supports STATIC_GATEWAY" "$SETUP" 'STATIC_GATEWAY'
assert_contains "setup-kiosk.sh supports STATIC_DNS" "$SETUP" 'STATIC_DNS'
assert_contains "setup-kiosk.sh passes ipv4.gateway to nmcli when set" \
    "$SETUP" 'ipv4.gateway'
assert_contains "setup-kiosk.sh passes ipv4.dns to nmcli when set" \
    "$SETUP" 'ipv4.dns'
assert_contains "Makefile documents STATIC_GATEWAY" "$REPO_ROOT/Makefile" 'STATIC_GATEWAY'
assert_contains "setup-kiosk.sh tells the user how to activate kiosk-static now" \
    "$SETUP" 'nmcli connection up kiosk-static'

# ============================================================================
echo ""
echo "=== Volunteer URL Token-Source Tests ==="
# ============================================================================
# The live token is the rotatable /var/lib/kiosk-web/token (app-owned; written
# on first rotation); /etc/kiosk-web.conf's TOKEN= is only the install seed.
# volunteer-web-url must prefer the store, else every URL it generates after a
# rotation carries the dead seed token (found on-Pi 2026-07-06, issue #11).
assert_contains "Makefile volunteer-web-url reads the rotatable token store" \
    "$REPO_ROOT/Makefile" '/var/lib/kiosk-web/token'
assert_contains "Makefile volunteer-web-url falls back to the conf seed token" \
    "$REPO_ROOT/Makefile" 'TOKEN=. /etc/kiosk-web.conf'

# deploy.sh's kiosk_manager.py freshness diff must run as root: the repo copy
# lives under /home/kiosk (0700), unreadable to the deploy user, so a plain
# diff always fails and the block reinstalled + RESTARTED kiosk-web on every
# deploy — a ~1s 502 for anyone using the manager (found on-Pi 2026-07-06).
assert_contains "deploy.sh kiosk-web freshness diff runs as root (0700 /home/kiosk)" \
    "$DEPLOY" 'sudo diff -q \${REMOTE_DIR}/web/kiosk_manager.py'

# ============================================================================
echo ""
echo "=== Kiosk Web Manager Tests (Python) ==="
# ============================================================================
# Auto-create a small venv with flask+pillow+pytest on first run; re-use after.

KIOSK_WEB_VENV="$SCRIPT_DIR/kiosk-web-venv"
if [[ ! -x "$KIOSK_WEB_VENV/bin/pytest" ]]; then
    echo "  Setting up Python test venv (first run only)…"
    python3 -m venv "$KIOSK_WEB_VENV"
    "$KIOSK_WEB_VENV/bin/pip" install --quiet \
        -r "$SCRIPT_DIR/requirements-kiosk-web.txt"
fi

PY_OUTPUT=$("$KIOSK_WEB_VENV/bin/pytest" "$SCRIPT_DIR/test_kiosk_manager.py" \
    -v --tb=short 2>&1) && PY_EXIT=0 || PY_EXIT=$?
echo "$PY_OUTPUT"

if [[ $PY_EXIT -eq 0 ]]; then
    PY_PASS=$(echo "$PY_OUTPUT" | grep -oP '\d+(?= passed)' | tail -1 || echo 0)
    PASS=$((PASS + ${PY_PASS:-0}))
    printf "${GREEN}  PASS${RESET} kiosk_manager.py unit tests (%s assertions)\n" "${PY_PASS:-?}"
else
    FAIL=$((FAIL + 1))
    ERRORS+=("kiosk_manager.py Python unit tests failed (see pytest output above)")
    printf "${RED}  FAIL${RESET} kiosk_manager.py unit tests\n"
fi

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
