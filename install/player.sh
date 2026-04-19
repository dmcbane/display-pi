#!/bin/bash
#
# Kiosk player loop:
#   1. Runs boot-time assessment (diagnostics → HDMI)
#   2. Waits for nginx RTMP readiness
#   3. Shows splash while stream is idle
#   4. Switches to mpv when stream goes live
#   5. Returns to splash when stream ends / mpv exits
#
# Runs under cage (Wayland kiosk compositor) as the kiosk user.

set -u

LOG=/tmp/player.log
exec >> "$LOG" 2>&1

STREAM_URL="rtmp://127.0.0.1/live/church242"
SPLASH_IMAGE="/home/kiosk/splash.png"
VOLUME=80
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ASSESS_SCRIPT="${SCRIPT_DIR}/assess.sh"
DIAG_SCRIPT="$(dirname "$SCRIPT_DIR")/diagnostics/render-status.sh"

# ---------------------------------------------------------------------------
# Boot-time assessment — shows diagnostics on HDMI, waits for critical
# services (network, nginx) before proceeding.
# ---------------------------------------------------------------------------
if [[ -x "$ASSESS_SCRIPT" ]]; then
    echo "[$(date)] running boot assessment"
    KIOSK_DIR="$(dirname "$SCRIPT_DIR")" "$ASSESS_SCRIPT" || {
        echo "[$(date)] assessment failed (exit $?), continuing anyway"
    }
else
    echo "[$(date)] WARN: assess.sh not found at $ASSESS_SCRIPT, skipping"
fi

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

show_splash() {
    mpv --fullscreen --really-quiet --loop \
        --image-display-duration=inf \
        --no-input-default-bindings \
        --no-audio \
        "$SPLASH_IMAGE" &
    echo $!
}

stream_live() {
    timeout 10 ffprobe \
        -v quiet \
        -show_entries stream=codec_type \
        -of default=nw=1:nk=1 \
        "$STREAM_URL" 2>/dev/null | grep -q .
}

wait_for_nginx() {
    until nc -z 127.0.0.1 1935 2>/dev/null; do
        echo "[$(date)] waiting for nginx RTMP port..."
        sleep 2
    done
    echo "[$(date)] nginx RTMP ready"
}

# Render and briefly show diagnostics (used on mpv crash/error)
show_error_diagnostics() {
    if [[ -x "$DIAG_SCRIPT" ]]; then
        KIOSK_DIR="$(dirname "$SCRIPT_DIR")" "$DIAG_SCRIPT" /tmp/kiosk-status.png >/dev/null 2>&1 || true
        timeout 5 mpv --fullscreen --really-quiet \
            --image-display-duration=5 \
            --no-input-default-bindings \
            --no-audio \
            /tmp/kiosk-status.png 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
consecutive_failures=0

while true; do
    echo "[$(date)] loop top"

    # Ensure nginx is up (handles mid-run nginx restarts)
    wait_for_nginx

    if ! stream_live; then
        echo "[$(date)] stream not live, showing splash"
        SPLASH_PID=$(show_splash)
        while ! stream_live; do
            echo "[$(date)] still waiting for stream..."
            sleep 3
        done
        echo "[$(date)] stream detected, killing splash $SPLASH_PID"
        kill "$SPLASH_PID" 2>/dev/null || true
        wait "$SPLASH_PID" 2>/dev/null || true
    fi

    echo "[$(date)] launching mpv"
    mpv_exit=0
    mpv --fullscreen \
        --hwdec=auto-safe \
        --cache=yes --demuxer-max-bytes=8MiB \
        --demuxer-readahead-secs=5 \
        --audio-device=auto \
        --volume="$VOLUME" \
        --no-correct-pts \
        --hr-seek=no \
        --stream-lavf-o=fflags=+genpts+igndts+discardcorrupt \
        --stream-lavf-o=analyzeduration=5000000 \
        --no-osc --no-osd-bar \
        --no-input-default-bindings \
        --really-quiet \
        --msg-level=all=warn \
        "$STREAM_URL" || mpv_exit=$?

    echo "[$(date)] mpv exited: $mpv_exit"

    if [[ "$mpv_exit" -ne 0 && "$mpv_exit" -ne 4 ]]; then
        # mpv exit 4 = normal EOF (stream ended). Other non-zero = problem.
        consecutive_failures=$((consecutive_failures + 1))
        echo "[$(date)] consecutive failures: $consecutive_failures"
        if [[ "$consecutive_failures" -ge 3 ]]; then
            echo "[$(date)] too many failures, showing diagnostics"
            show_error_diagnostics
            consecutive_failures=0
        fi
    else
        consecutive_failures=0
    fi

    sleep 2
done
