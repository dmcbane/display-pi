#!/bin/bash
#
# set-pi-time.sh — Push the laptop's clock to the Pi.
#
# Primary use case: offline venue where systemd-timesyncd has no upstream
# and the Pi (no RTC battery) has drifted off after a power cycle. Sets
# the Pi's wall clock to the laptop's clock at the moment of invocation,
# plus an optional OFFSET in seconds to anticipate the SSH round-trip lag
# so the clock lands on the intended wall time instead of OFFSET-seconds
# behind it.
#
# We send the Unix epoch (seconds with microsecond precision) and use
# `date -s @<epoch>` on the Pi. Epoch is timezone-independent — the Pi's
# wall clock will reflect its own configured TZ correctly without us
# needing to know what that TZ is.
#
# `date -s` is intentionally NOT in install/kiosk-deploy.sudoers — clock
# setting is rare, root-level, and worth the password gate. Same recipe
# as dev/set-hdmi-mode.sh to make the remote sudo prompt work:
#   1. `ssh -t` allocates a remote PTY (sudo reads passwords from /dev/tty).
#   2. The remote script is sent as a command argument; we do NOT feed it
#      via `bash -s <<<…`, which would close local stdin and leave the
#      password prompt with no input source.
#
# Usage:
#   dev/set-pi-time.sh <HOST> [OFFSET_SEC]
#
# Examples:
#   dev/set-pi-time.sh displaypi          # current laptop time, no offset
#   dev/set-pi-time.sh displaypi 1.5      # add 1.5s to anticipate SSH lag
#   dev/set-pi-time.sh displaypi -0.5     # subtract half a second

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <HOST> [OFFSET_SEC]" >&2
    echo "  e.g.: $0 displaypi" >&2
    echo "        $0 displaypi 1.5" >&2
    exit 2
fi

HOST="$1"
OFFSET="${2:-0}"

# OFFSET must be numeric (integer or decimal, optional leading sign).
if ! [[ "$OFFSET" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERROR: OFFSET must be numeric (e.g. 0, 1.5, -0.25); got: $OFFSET" >&2
    exit 2
fi

log() { printf '\033[1;34m[set-pi-time]\033[0m %s\n' "$*"; }

# Laptop time + offset. bash arithmetic is integer-only, so use awk for
# portable floating-point math. Allow EPOCH to be overridden so the test
# suite can pin a known value.
EPOCH="${EPOCH:-$(date +%s.%N)}"
TARGET=$(awk -v e="$EPOCH" -v o="$OFFSET" 'BEGIN{printf "%.6f", e+o}')

log "Setting $HOST clock to $(date -d "@$TARGET" '+%Y-%m-%d %H:%M:%S.%6N %Z') (offset ${OFFSET}s)"

# Remote: print clock before, set it, print after. `sudo date -s @<epoch>`
# is timezone-agnostic.
ssh -t "$HOST" "echo 'Before: '\$(date '+%Y-%m-%d %H:%M:%S.%6N %Z'); \
    sudo date -s @${TARGET} > /dev/null && \
    echo 'After:  '\$(date '+%Y-%m-%d %H:%M:%S.%6N %Z')"
