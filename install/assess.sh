#!/bin/bash
#
# assess.sh — Boot-time situation assessment for kiosk display
#
# Called by player.sh before entering the main loop. Runs diagnostics,
# renders status to HDMI via mpv, and decides whether to proceed or
# hold on the status screen until critical issues resolve.
#
# Exit codes:
#   0 — all clear, proceed to player loop
#   1 — unrecoverable error (player.sh should restart via systemd)
#
# Environment:
#   ASSESS_HOLD_SECS  — seconds to show status when healthy (default: 8)
#   ASSESS_RETRY_SECS — seconds between retries when critical (default: 10)
#   KIOSK_DIR         — base directory for kiosk scripts (default: script's parent)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIOSK_DIR="${KIOSK_DIR:-$(dirname "$SCRIPT_DIR")}"
DIAG_SCRIPT="${KIOSK_DIR}/diagnostics/render-status.sh"
STATUS_PNG="/tmp/kiosk-status.png"
HOLD_SECS="${ASSESS_HOLD_SECS:-8}"
RETRY_SECS="${ASSESS_RETRY_SECS:-10}"
MAX_CRITICAL_RETRIES=30  # 30 * 10s = 5 minutes max wait

log() {
    echo "[$(date)] assess: $*"
}

# Show a PNG on screen for a given duration using mpv
# Args: png_path seconds
show_status_screen() {
    local png="$1"
    local secs="$2"
    if [[ ! -f "$png" ]]; then
        log "WARN: status PNG not found at $png"
        return 1
    fi
    timeout "$secs" mpv --fullscreen --really-quiet \
        --image-display-duration="$secs" \
        --no-input-default-bindings \
        --no-audio \
        "$png" 2>/dev/null || true
}

# Parse render-status.sh output to determine overall status
# Returns: OK, WARN, or FAIL
get_status() {
    local output="$1"
    echo "$output" | head -1 | sed -n 's/^status=\([A-Z]*\).*/\1/p'
}

# Check minimum viable conditions for the player loop:
# 1. Network interface has an IP
# 2. nginx is running and port 1935 is open
check_critical() {
    local has_ip=false
    local has_nginx=false

    if hostname -I 2>/dev/null | grep -q '[0-9]'; then
        has_ip=true
    fi

    if nc -z 127.0.0.1 1935 2>/dev/null; then
        has_nginx=true
    fi

    if $has_ip && $has_nginx; then
        return 0
    fi

    if ! $has_ip; then
        log "CRITICAL: no IP address"
    fi
    if ! $has_nginx; then
        log "CRITICAL: nginx RTMP port 1935 not open"
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Main assessment loop
# ---------------------------------------------------------------------------
main() {
    log "starting assessment"

    local retries=0

    while true; do
        # Render current status
        log "running diagnostics"
        local diag_output
        diag_output=$("$DIAG_SCRIPT" "$STATUS_PNG" 2>&1) || true
        local status
        status=$(get_status "$diag_output")
        log "diagnostic result: ${status:-UNKNOWN}"

        # Log full output
        echo "$diag_output" | tail -n +2

        if check_critical; then
            # System is viable — show status briefly, then proceed
            if [[ "$status" == "FAIL" ]]; then
                # Non-critical failures (disk full, etc.) — show longer
                log "non-critical failures detected, showing status for ${HOLD_SECS}s"
                show_status_screen "$STATUS_PNG" "$HOLD_SECS"
            elif [[ "$status" == "WARN" ]]; then
                log "warnings detected, showing status for ${HOLD_SECS}s"
                show_status_screen "$STATUS_PNG" "$HOLD_SECS"
            else
                # All OK — brief flash so operator knows it booted
                log "all clear, showing status for 4s"
                show_status_screen "$STATUS_PNG" 4
            fi
            log "assessment complete, proceeding to player loop"
            return 0
        fi

        # Critical failure — hold on status screen and retry
        retries=$((retries + 1))
        if [[ "$retries" -ge "$MAX_CRITICAL_RETRIES" ]]; then
            log "CRITICAL: max retries ($MAX_CRITICAL_RETRIES) exceeded, proceeding anyway"
            show_status_screen "$STATUS_PNG" "$HOLD_SECS"
            return 0
        fi

        log "critical issues, retry ${retries}/${MAX_CRITICAL_RETRIES} in ${RETRY_SECS}s"
        show_status_screen "$STATUS_PNG" "$RETRY_SECS"
    done
}

main "$@"
