#!/bin/bash
#
# healthcheck.sh — Ping an external healthcheck service to report kiosk liveness.
#
# Called by cron every 5 minutes. Determines kiosk health via check_health()
# and pings the configured URL on success or the URL+/fail suffix on failure.
# Silent on success; logs to syslog on failure.
#
# Config (via /etc/kiosk-healthcheck.conf, one VAR=value per line):
#   HEALTHCHECK_URL=https://hc-ping.com/<your-uuid>
#
# Or via environment (useful for testing):
#   HEALTHCHECK_URL=https://hc-ping.com/abc-123 ./healthcheck.sh

set -u

CONFIG_FILE="${HEALTHCHECK_CONFIG:-/etc/kiosk-healthcheck.conf}"
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"

log() {
    logger -t kiosk-healthcheck "$*"
}

# ---------------------------------------------------------------------------
# check_health — decide whether the kiosk is healthy right now.
#
# Returns 0 for healthy, non-zero for unhealthy.
# Echoes a short one-line reason (used as ping body for observability).
#
# USER-CONTRIBUTED: this is the policy decision that shapes what the
# external monitor sees. See the discussion in the deploy message for
# design guidance.
# ---------------------------------------------------------------------------
check_health() {
    # Network: we have an IP, a default route, and a live physical link.
    # Any of these failing means we cannot receive RTMP from the ATEM.
    if ! hostname -I 2>/dev/null | grep -q '[0-9]'; then
        echo "no IP address assigned"
        return 1
    fi
    if ! ip -4 route show default 2>/dev/null | grep -q default; then
        echo "no default route"
        return 1
    fi
    local iface
    iface=$(ip -4 route show default | awk '{print $5; exit}')
    if [[ -n "$iface" ]]; then
        local state
        state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo unknown)
        if [[ "$state" != "up" ]]; then
            echo "${iface} operstate=${state}"
            return 1
        fi
    fi

    # Compositor: without cage, HDMI shows nothing.
    if ! pgrep -f 'cage -s' >/dev/null; then
        echo "cage compositor not running"
        return 1
    fi

    # Player loop: without it, no splash/stream switching happens.
    if ! pgrep -f 'bin/player.sh' >/dev/null; then
        echo "player.sh not running"
        return 1
    fi

    # nginx RTMP ingest: without it, ATEM cannot push.
    if ! nc -z 127.0.0.1 1935 2>/dev/null; then
        echo "nginx RTMP port 1935 not listening"
        return 1
    fi

    # Log freshness: catches hangs where processes are alive but the loop
    # is stuck (see the SPLASH_PID=$() pipe bug in git history).
    # 15-min window tolerates quiet periods during stable streams.
    if [[ -f /tmp/player.log ]] && [[ -z "$(find /tmp/player.log -mmin -15 2>/dev/null)" ]]; then
        echo "player.log has had no writes in 15+ minutes"
        return 1
    fi

    echo "ok ($(hostname -I | awk '{print $1}'), iface=${iface:-?})"
    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
if [[ -z "$HEALTHCHECK_URL" ]]; then
    log "HEALTHCHECK_URL not set in $CONFIG_FILE; skipping ping"
    exit 0
fi

reason=$(check_health)
status=$?

if [[ "$status" -eq 0 ]]; then
    # Success — ping the base URL
    curl -fsS -m "$TIMEOUT" --retry 2 \
        --data-raw "$reason" \
        "$HEALTHCHECK_URL" >/dev/null || \
        log "Healthy but ping failed to $HEALTHCHECK_URL"
else
    # Failure — ping the /fail endpoint with reason as body
    log "Unhealthy: $reason"
    curl -fsS -m "$TIMEOUT" --retry 2 \
        --data-raw "$reason" \
        "${HEALTHCHECK_URL}/fail" >/dev/null || \
        log "Fail ping also failed to ${HEALTHCHECK_URL}/fail"
fi
