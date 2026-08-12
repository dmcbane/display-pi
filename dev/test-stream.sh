#!/bin/bash
#
# test-stream.sh — Send a test RTMP stream to the Pi
#
# Generates a 1080p test pattern with tone for verifying the full path:
# ffmpeg → nginx RTMP → mpv → HDMI
#
# Usage: test-stream.sh [host] [duration_secs]
# Default host: displaypi, default duration: 60

set -euo pipefail

HOST="${1:-${KIOSK_HOST:-displaypi}}"
DURATION="${2:-60}"
STREAM_KEY="${STREAM_KEY:-restoration}"
RTMP_APP="${RTMP_APP:-live}"

# Resolve via SSH config if possible (handles cases where the short name
# is an SSH alias but DNS points elsewhere — e.g. AT&T attlocal.net).
RTMP_TARGET="$HOST"
if resolved=$(ssh -G "$HOST" 2>/dev/null | awk '/^hostname / {print $2}'); then
    if [[ -n "$resolved" && "$resolved" != "$HOST" ]]; then
        RTMP_TARGET="$resolved"
    fi
fi
RTMP_URL="rtmp://${RTMP_TARGET}/${RTMP_APP}/${STREAM_KEY}"

log()  { printf '\033[1;34m[test-stream]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[test-stream] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[test-stream] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v ffmpeg >/dev/null || die "ffmpeg not found"

# --- Preflight -------------------------------------------------------------
#
# Two misconfigurations make this script fail without naming a cause:
#
#   1. nginx restricts publishing to RTMP_ALLOW_PUBLISH_CIDRS. From outside
#      that range the server drops the connection at handshake and ffmpeg
#      prints "Broken pipe" — 40 lines of libx264 statistics later.
#   2. The key we publish under differs from the one player.sh watches. nginx
#      accepts any key inside the app, so the publish SUCCEEDS and the display
#      just never switches. No error appears anywhere.
#
# Both are answerable before ffmpeg starts, by reading the Pi's own config.

ip_to_int() {
    local IFS=. a b c d
    read -r a b c d <<<"$1"
    printf '%s' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# cidr_contains <ip> <cidr>  — exit 0 if ip falls inside cidr. A bare address
# with no /bits is treated as a single host (/32), matching nginx.
cidr_contains() {
    local ip="$1" cidr="$2" net bits mask
    net="${cidr%/*}"
    if [[ "$cidr" == */* ]]; then bits="${cidr#*/}"; else bits=32; fi
    [[ "$bits" =~ ^[0-9]+$ ]] && (( bits <= 32 )) || return 1
    # A /0 mask can't be produced by shifting a 32-bit value left by 32.
    if (( bits == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF )); fi
    (( ($(ip_to_int "$ip") & mask) == ($(ip_to_int "$net") & mask) ))
}

# Pull the allow-publish CIDRs out of a rendered nginx.conf. Anchored on the
# directive so a comment line that merely mentions "allow publish" is ignored.
parse_nginx_allow() {
    sed -n 's/^[[:space:]]*allow[[:space:]]\+publish[[:space:]]\+\([^;]*\);.*/\1/p' | tr '\n' ' ' | sed 's/ *$//'
}

# Read what decides whether this run can work. Two sources, and the difference
# between them matters:
#
#   /etc/nginx/nginx.conf   what nginx is enforcing RIGHT NOW — the authority,
#                           because this is what accepts or denies the publish
#   /etc/default/kiosk      what the config store INTENDS
#
# `kiosk-config` writes the second; only `make deploy` re-renders the first.
# Between those two moments they disagree, and checking the intended value
# there yields a false green — the preflight blesses the run and nginx denies
# it anyway. So: check nginx, and report the gap when there is one.
#
# A Pi we can't SSH into is not fatal — the RTMP port may still be reachable —
# so the preflight degrades to a warning rather than blocking the stream.
PI_CIDRS=""; PI_KEY=""; PI_APP=""; NGINX_CIDRS=""
if pi_conf=$(timeout 10 ssh -o BatchMode=yes "$HOST" '
        sudo grep -hE "^(RTMP_ALLOW_PUBLISH_CIDRS|STREAM_KEY|RTMP_APP)=" /etc/default/kiosk
        echo "@@NGINX@@"
        sudo grep -hE "^[[:space:]]*allow[[:space:]]+publish" /etc/nginx/nginx.conf
    ' 2>/dev/null); then
    kiosk_part=${pi_conf%%@@NGINX@@*}
    nginx_part=${pi_conf#*@@NGINX@@}
    PI_CIDRS=$(sed -n 's/^RTMP_ALLOW_PUBLISH_CIDRS=//p' <<<"$kiosk_part" | tr -d '"')
    PI_KEY=$(sed -n 's/^STREAM_KEY=//p' <<<"$kiosk_part" | tr -d '"')
    PI_APP=$(sed -n 's/^RTMP_APP=//p' <<<"$kiosk_part" | tr -d '"')
    NGINX_CIDRS=$(parse_nginx_allow <<<"$nginx_part")

    # Drift: someone edited the config store and never re-rendered nginx.
    if [[ -n "$NGINX_CIDRS" && -n "$PI_CIDRS" && "$NGINX_CIDRS" != "$PI_CIDRS" ]]; then
        warn "the Pi's configured allow-list is not yet applied to nginx:"
        warn "  /etc/default/kiosk:      $PI_CIDRS"
        warn "  nginx is enforcing:      $NGINX_CIDRS"
        warn "Run 'make deploy' to re-render nginx.conf and reload. Checking"
        warn "against what nginx is actually enforcing."
    fi
else
    warn "couldn't read /etc/default/kiosk on $HOST — preflight skipped."
    warn "If the stream fails with 'Broken pipe', this workstation is probably"
    warn "outside the Pi's RTMP_ALLOW_PUBLISH_CIDRS allow-list."
fi

# The Pi's key is the only one that makes the display switch, so it wins over
# the local default. Say so — a silent substitution is its own kind of trap.
if [[ -n "$PI_KEY" && "$PI_KEY" != "$STREAM_KEY" ]]; then
    log "Using the Pi's stream key '$PI_KEY' (local value was '$STREAM_KEY')."
    STREAM_KEY="$PI_KEY"
fi
[[ -n "$PI_APP" && "$PI_APP" != "$RTMP_APP" ]] && RTMP_APP="$PI_APP"

# Check against what nginx enforces; fall back to the config store only if the
# nginx read came back empty (unexpected layout, or an older Pi).
ACL_CIDRS="${NGINX_CIDRS:-$PI_CIDRS}"
ACL_SOURCE="nginx.conf"
[[ -n "$NGINX_CIDRS" ]] || ACL_SOURCE="/etc/default/kiosk (nginx.conf unreadable)"

# Which of our addresses will nginx actually see? Ask the routing table for the
# source it would pick for this destination, rather than guessing at `hostname
# -I`, which lists every interface including ones that can't reach the Pi.
if [[ -n "$ACL_CIDRS" ]] && command -v ip >/dev/null; then
    probe="$RTMP_TARGET"
    if [[ ! "$probe" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        probe=$(getent ahostsv4 "$probe" 2>/dev/null | awk 'NR==1 {print $1}')
    fi
    src_ip=$(ip route get "$probe" 2>/dev/null | grep -oP '\bsrc \K[0-9.]+' | head -1)

    if [[ -z "$src_ip" ]]; then
        warn "couldn't determine this host's source address toward $probe — publish-ACL check skipped."
    else
        allowed=0
        for cidr in $ACL_CIDRS; do
            if cidr_contains "$src_ip" "$cidr"; then allowed=1; break; fi
        done
        if (( ! allowed )); then
            die "$(cat <<EOF
this workstation cannot publish to $HOST.

  your source address:      $src_ip
  nginx allows publish from: $ACL_CIDRS

nginx will accept the TCP connection and then drop it, which ffmpeg reports
only as "Broken pipe". Fix it on the Pi — the persisted value in
/etc/default/kiosk wins over the repo default:

  # add your subnet to RTMP_ALLOW_PUBLISH_CIDRS, then re-render nginx:
  ssh $HOST 'sudo kiosk-config'
  make deploy

Narrow it again before the Pi goes into service; that list is the real
control on who can push to the display.
EOF
)"
        fi
        log "Publish ACL: $src_ip is inside '$ACL_CIDRS' (per $ACL_SOURCE)."
    fi
fi

# Rebuild the URL — the key and app may have been corrected above.
RTMP_URL="rtmp://${RTMP_TARGET}/${RTMP_APP}/${STREAM_KEY}"
# --- End preflight ---------------------------------------------------------

log "Streaming test pattern to ${RTMP_URL} for ${DURATION}s..."
log "Press Ctrl-C to stop early"

ffmpeg -re \
    -f lavfi -i "testsrc=size=1920x1080:rate=30" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t "$DURATION" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -pix_fmt yuv420p \
    -g 60 -keyint_min 60 \
    -c:a aac -b:a 128k \
    -f flv \
    "$RTMP_URL"

log "Test stream ended"
