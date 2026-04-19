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
STREAM_KEY="${STREAM_KEY:-church242}"
RTMP_APP="${RTMP_APP:-live}"
RTMP_URL="rtmp://${HOST}/${RTMP_APP}/${STREAM_KEY}"

log() { printf '\033[1;34m[test-stream]\033[0m %s\n' "$*"; }

command -v ffmpeg >/dev/null || { log "ERROR: ffmpeg not found"; exit 1; }

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
