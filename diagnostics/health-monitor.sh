#!/bin/bash
#
# health-monitor.sh — Background daemon that writes current health state
# to /tmp/kiosk-health.json every POLL_SEC seconds. The mpv overlay
# Lua script reads this file and renders a corner indicator on HDMI.
#
# Launched from player.sh as a background process. Shares the check_health()
# policy with install/healthcheck.sh (sourced into this script at startup).
#
# File format (simple flat JSON):
#   {"status": "OK|WARN|FAIL", "message": "short reason", "updated": "ISO8601"}

set -u

HEALTH_FILE="${HEALTH_FILE:-/tmp/kiosk-health.json}"
POLL_SEC="${HEALTH_POLL_SEC:-20}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HEALTHCHECK_SH="$(dirname "$SCRIPT_DIR")/install/healthcheck.sh"

if [[ ! -r "$HEALTHCHECK_SH" ]]; then
    echo "health-monitor: cannot read $HEALTHCHECK_SH" >&2
    exit 1
fi

# Extract just the check_health() function from healthcheck.sh so we
# reuse the exact same policy. Requires the function to start with
# `check_health()` and end with a lone `}` at column 0 (our style).
eval "$(sed -n '/^check_health()/,/^}$/p' "$HEALTHCHECK_SH")"

# Map check_health exit code + reason string to a status level.
# Reasons that mention hardware / kiosk-fatal conditions are FAIL,
# network/transient conditions are WARN.
classify() {
    local reason="$1" status_code="$2"
    if [[ "$status_code" -eq 0 ]]; then
        echo "OK"
        return
    fi
    case "$reason" in
        *"cage compositor"*|*"player.sh not running"*|*"no IP"*|*"no default route"*|*"operstate"*)
            echo "FAIL"
            ;;
        *)
            echo "WARN"
            ;;
    esac
}

# Escape a string for JSON (double-quoted value). Handle backslash, quote,
# and control characters.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

write_snapshot() {
    local reason status status_code level
    reason=$(check_health 2>&1)
    status_code=$?
    level=$(classify "$reason" "$status_code")

    local tmp="${HEALTH_FILE}.tmp"
    printf '{"status":"%s","message":"%s","updated":"%s"}\n' \
        "$level" \
        "$(json_escape "$reason")" \
        "$(date -Iseconds)" \
        > "$tmp"
    mv -f "$tmp" "$HEALTH_FILE"
}

# Write once immediately, then loop.
write_snapshot
while true; do
    sleep "$POLL_SEC"
    write_snapshot
done
