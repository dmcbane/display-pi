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

# Stream config comes from /etc/default/kiosk (written by setup-kiosk.sh,
# loaded by kiosk.service via EnvironmentFile=). When run outside the service
# (manual debugging), read the file directly so behavior matches the service.
# The hardcoded default only applies on a Pi that was never set up.
if [[ -z "${STREAM_URL:-}" && -r /etc/default/kiosk ]]; then
    STREAM_URL="$(. /etc/default/kiosk 2>/dev/null; echo "${STREAM_URL:-}")"
fi
STREAM_URL="${STREAM_URL:-rtmp://127.0.0.1/live/restoration}"
# Splash images. The kiosk cycles through the images in $SPLASH_DIR, advancing
# by ONE each time the idle splash is (re)entered (no timer — the image only
# changes when the stream drops and the splash comes back up). $SPLASH_IMAGE is
# the legacy single-image fallback used when the folder is empty/missing. The
# rotation cursor is persisted to $SPLASH_STATE so it advances across service
# restarts (an in-memory counter would reset to the first image every restart);
# this is what makes `make restart` step to the next slide during testing. All
# overridable via /etc/default/kiosk (kiosk.service EnvironmentFile).
SPLASH_DIR="${SPLASH_DIR:-/home/kiosk/splash.d}"
SPLASH_IMAGE="${SPLASH_IMAGE:-/home/kiosk/splash.png}"
SPLASH_STATE="${SPLASH_STATE:-/home/kiosk/.splash-index}"
# mpv volume 0-100. Persisted as VOLUME in /etc/default/kiosk by setup-kiosk.sh
# (from PLAYBACK_VOLUME), so a custom volume survives deploys.
VOLUME="${VOLUME:-80}"
# How often the idle loop re-probes for a live publisher. This is the dominant
# term in splash->stream switch latency: the display stays on splash for up to
# this long after the ATEM/publisher goes live. ffprobe fails fast (~0.45s)
# against an idle stream, so a tight 1s poll is cheap. Env-overridable.
STREAM_POLL_INTERVAL="${STREAM_POLL_INTERVAL:-1}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ASSESS_SCRIPT="${SCRIPT_DIR}/assess.sh"
DIAG_SCRIPT="$(dirname "$SCRIPT_DIR")/diagnostics/render-status.sh"
HEALTH_MONITOR="$(dirname "$SCRIPT_DIR")/diagnostics/health-monitor.sh"
OVERLAY_SCRIPT="${SCRIPT_DIR}/mpv-health-overlay.lua"

# Runtime HDMI mode enforcement. HDMI_MODE and HDMI_OUTPUT come from
# /etc/default/kiosk (loaded by kiosk.service via EnvironmentFile=) and
# are written by install/setup-kiosk.sh and dev/set-hdmi-mode.sh. The
# kernel `video=HDMI-A-1:<mode>` cmdline parameter is a best-effort hint
# that some panels' EDID overrides; this is the authoritative layer.
# Empty HDMI_MODE skips enforcement (lets EDID pick).
HDMI_MODE="${HDMI_MODE:-}"
HDMI_OUTPUT="${HDMI_OUTPUT:-HDMI-A-1}"

# ---------------------------------------------------------------------------
# Runtime mode enforcement — wlr-randr sets the active mode authoritatively
# within the cage session. Logged for forensics; failure is non-fatal.
#
# nearest_refresh_for: read wlr-randr output on stdin, take a target like
# "1920x1080@30" as $1, print the closest mode in WIDTHxHEIGHT@RATE form
# (RATE is the EDID-reported decimal, e.g. "30.003000"). Pi 5 / Trixie
# panels often report 30Hz as 30.003 Hz; an exact "@30" string match
# rejects everything. This resolver matches the resolution first, then
# picks the smallest |actual_rate - target_rate|.
# ---------------------------------------------------------------------------
nearest_refresh_for() {
    awk -v target="$1" '
        BEGIN {
            n = split(target, parts, "@")
            if (n != 2) exit
            target_wh = parts[1]
            target_rate = parts[2] + 0
        }
        $1 ~ /^[0-9]+x[0-9]+$/ && $2 == "px," && $4 == "Hz" && $1 == target_wh {
            diff = ($3 > target_rate) ? $3 - target_rate : target_rate - $3
            if (best_rate == "" || diff < best_diff) {
                best_rate = $3
                best_diff = diff
            }
        }
        END {
            if (best_rate != "") print target_wh "@" best_rate
        }
    '
}

force_display_mode() {
    if [[ -z "$HDMI_MODE" ]]; then
        echo "[$(date)] HDMI_MODE unset, leaving EDID-preferred mode active"
        return 0
    fi
    if ! command -v wlr-randr >/dev/null 2>&1; then
        echo "[$(date)] WARN: wlr-randr not installed; cannot enforce $HDMI_MODE"
        return 0
    fi
    local resolved
    resolved=$(wlr-randr 2>/dev/null | nearest_refresh_for "$HDMI_MODE")
    if [[ -z "$resolved" ]]; then
        echo "[$(date)] WARN: no $HDMI_MODE match in wlr-randr output; leaving active mode"
        return 0
    fi
    echo "[$(date)] forcing $HDMI_OUTPUT: requested $HDMI_MODE, resolved $resolved"
    wlr-randr --output "$HDMI_OUTPUT" --mode "$resolved" \
        > /tmp/kiosk-wlr-randr.log 2>&1 || {
            echo "[$(date)] WARN: wlr-randr failed (exit $?); continuing with active mode"
        }
}
force_display_mode

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
# Health monitor — writes /tmp/kiosk-health.json every 20s so the mpv
# overlay script can show a status indicator in the bottom-right corner.
# Started as a background child; dies with player.sh when systemd restarts us.
# ---------------------------------------------------------------------------
if [[ -x "$HEALTH_MONITOR" ]]; then
    echo "[$(date)] starting health monitor"
    "$HEALTH_MONITOR" </dev/null >>"$LOG" 2>&1 &
fi

# Compose the --script flag only if the overlay file exists.
OVERLAY_FLAG=()
if [[ -f "$OVERLAY_SCRIPT" ]]; then
    OVERLAY_FLAG=(--script="$OVERLAY_SCRIPT")
fi

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

# Pick the next splash image and advance the rotation cursor. MUST run in the
# parent shell — `SPLASH_PID=$(show_splash ...)` runs show_splash in a subshell,
# so a cursor advanced there would be lost. We therefore return the path via the
# global SPLASH_NEXT and mutate SPLASH_INDEX directly here. The folder is
# re-read every call so images added between services appear at the next splash
# entry. Returns non-zero (touching nothing) when no usable image exists, so the
# caller can surface that loudly rather than silently showing a blank screen.
next_splash_image() {
    local images=()
    if [[ -d "$SPLASH_DIR" ]]; then
        while IFS= read -r -d '' f; do
            images+=("$f")
        done < <(find -L "$SPLASH_DIR" -maxdepth 1 -type f \
            \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0 \
            2>/dev/null | sort -z)
    fi
    if (( ${#images[@]} == 0 )); then
        # Empty/missing folder — fall back to the legacy single image.
        if [[ -f "$SPLASH_IMAGE" ]]; then
            SPLASH_NEXT="$SPLASH_IMAGE"
            return 0
        fi
        return 1
    fi
    # Read the persisted cursor, show that image, then store the next index.
    # Persisting (vs an in-memory counter) keeps rotation advancing across
    # service restarts/crashes instead of snapping back to the first slide.
    local idx=0
    if [[ -r "$SPLASH_STATE" ]]; then
        idx=$(< "$SPLASH_STATE")
        [[ "$idx" =~ ^[0-9]+$ ]] || idx=0
    fi
    SPLASH_NEXT="${images[idx % ${#images[@]}]}"
    echo $(( (idx + 1) % ${#images[@]} )) > "$SPLASH_STATE" 2>/dev/null || true
    return 0
}

show_splash() {
    # $1 is the splash image to display. Redirect mpv's stdout/stderr to $LOG
    # explicitly. Without this, mpv inherits the command-substitution pipe from
    # SPLASH_PID=$(show_splash ...) and bash blocks on pipe_read waiting for EOF
    # that never arrives. --loop + --image-display-duration=inf holds the single
    # decoded frame forever (zero flicker); rotation happens between entries via
    # next_splash_image, not inside mpv.
    mpv --fullscreen --really-quiet --loop \
        --image-display-duration=inf \
        --no-input-default-bindings \
        --no-audio \
        "${OVERLAY_FLAG[@]}" \
        "$1" </dev/null >>"$LOG" 2>&1 &
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
        if next_splash_image; then
            echo "[$(date)] stream not live, showing splash: $SPLASH_NEXT"
            SPLASH_PID=$(show_splash "$SPLASH_NEXT")
        else
            # Don't fail silently: a blank idle screen is itself a fault.
            echo "[$(date)] ERROR: no splash image in $SPLASH_DIR or $SPLASH_IMAGE"
            show_error_diagnostics
            SPLASH_PID=""
        fi
        while ! stream_live; do
            echo "[$(date)] still waiting for stream..."
            sleep "$STREAM_POLL_INTERVAL"
        done
        if [[ -n "$SPLASH_PID" ]]; then
            echo "[$(date)] stream detected, killing splash $SPLASH_PID"
            kill "$SPLASH_PID" 2>/dev/null || true
            wait "$SPLASH_PID" 2>/dev/null || true
        fi
    fi

    echo "[$(date)] launching mpv"
    mpv_exit=0
    mpv --fullscreen \
        --hwdec=v4l2m2m-copy \
        --cache=yes --demuxer-max-bytes=8MiB \
        --demuxer-readahead-secs=2 \
        --audio-device=alsa/plughw:CARD=vc4hdmi0,DEV=0 \
        --volume="$VOLUME" \
        --video-sync=audio \
        --hr-seek=no \
        --stream-lavf-o=fflags=+discardcorrupt \
        --stream-lavf-o=analyzeduration=5000000 \
        --no-osc --no-osd-bar \
        --no-input-default-bindings \
        --really-quiet \
        --msg-level=all=warn \
        "${OVERLAY_FLAG[@]}" \
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
