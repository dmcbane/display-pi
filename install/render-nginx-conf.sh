#!/bin/bash
#
# render-nginx-conf.sh — render nginx.conf from the repo template with the
# Pi's configured RTMP app and allow-publish CIDRs.
#
# install/nginx.conf is the single source of truth for nginx structure; the
# per-Pi values (RTMP_APP, RTMP_ALLOW_PUBLISH_CIDRS) live in /etc/default/kiosk
# (written by setup-kiosk.sh). Both setup-kiosk.sh and deploy.sh render through
# this script, so a deploy can never revert a configured app name or CIDR list
# to the template defaults.
#
# Usage: render-nginx-conf.sh <template> [env-file]
#   Prints the rendered config to stdout.
#   RTMP_APP / RTMP_ALLOW_PUBLISH_CIDRS env vars override the env-file values;
#   with neither set, the template's own defaults are reproduced exactly.

set -euo pipefail

TEMPLATE="${1:?usage: render-nginx-conf.sh <template> [env-file]}"
ENV_FILE="${2:-${KIOSK_ENV_FILE:-/etc/default/kiosk}}"

[[ -r "$TEMPLATE" ]] || { echo "ERROR: template not readable: $TEMPLATE" >&2; exit 1; }

# Fill unset values from the env file (a subshell so nothing leaks), then
# fall back to the template defaults.
if [[ -r "$ENV_FILE" ]]; then
    [[ -n "${RTMP_APP:-}" ]] || \
        RTMP_APP="$(. "$ENV_FILE" 2>/dev/null; echo "${RTMP_APP:-}")"
    [[ -n "${RTMP_ALLOW_PUBLISH_CIDRS:-}" ]] || \
        RTMP_ALLOW_PUBLISH_CIDRS="$(. "$ENV_FILE" 2>/dev/null; echo "${RTMP_ALLOW_PUBLISH_CIDRS:-}")"
fi
RTMP_APP="${RTMP_APP:-live}"
RTMP_ALLOW_PUBLISH_CIDRS="${RTMP_ALLOW_PUBLISH_CIDRS:-192.168.0.0/24}"

# Rewrite the application name and replace the contiguous run of
# `allow publish` lines with one line per configured CIDR (same indent).
awk -v app="$RTMP_APP" -v cidrs="$RTMP_ALLOW_PUBLISH_CIDRS" '
    /^[[:space:]]*application[[:space:]]+[^ ]+[[:space:]]*\{/ {
        sub(/application[[:space:]]+[^ ]+/, "application " app)
    }
    /^[[:space:]]*allow publish / {
        if (!emitted) {
            match($0, /^[[:space:]]*/)
            indent = substr($0, 1, RLENGTH)
            n = split(cidrs, arr, /[[:space:]]+/)
            for (i = 1; i <= n; i++)
                if (arr[i] != "") printf "%sallow publish %s;\n", indent, arr[i]
            emitted = 1
        }
        next
    }
    { print }
' "$TEMPLATE"
