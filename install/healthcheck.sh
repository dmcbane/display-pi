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
    # TODO: implement the health policy.
    # Available building blocks you can use:
    #   - nc -z 127.0.0.1 1935          # nginx RTMP port open
    #   - systemctl is-active nginx     # nginx service running
    #   - pgrep -f 'bin/player.sh'      # player loop alive
    #   - pgrep -f 'cage -s'            # kiosk compositor alive
    #   - tail -c 512 /tmp/player.log   # recent log activity
    #   - ffprobe ... rtmp://127.0.0.1/live/church242  # stream currently live
    #
    # Return 0 and echo a short reason string on healthy.
    # Return non-zero and echo the problem on unhealthy.
    echo "check_health() not implemented"
    return 1
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
