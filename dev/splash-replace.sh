#!/bin/bash
#
# splash-replace — volunteer-facing script (macOS/Linux).
#
# Replaces the splash image on the church-display Pi. Validates the file
# locally first (so an obviously-wrong file fails fast with a clear
# message), then uploads via SSH to the kiosk. The Pi re-validates on
# arrival and refuses to install anything that isn't a 1920x1080 PNG.
#
# Usage:
#   splash-replace.sh <path/to/image.png>
#
# Optional environment:
#   SPLASH_HOST       Override the Pi hostname/IP (default: displaypi)
#   SPLASH_KEY        Override path to the SSH private key
#                     (default: ./splash-updater next to this script,
#                      then ~/.ssh/splash-updater)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="${SPLASH_HOST:-displaypi}"

# Find the SSH key: bundled next to script first, then ~/.ssh, else die.
if [[ -n "${SPLASH_KEY:-}" ]]; then
    KEY="$SPLASH_KEY"
elif [[ -f "$SCRIPT_DIR/splash-updater" ]]; then
    KEY="$SCRIPT_DIR/splash-updater"
elif [[ -f "$HOME/.ssh/splash-updater" ]]; then
    KEY="$HOME/.ssh/splash-updater"
else
    echo "ERROR: SSH key not found." >&2
    echo "       Place the splash-updater key file next to this script," >&2
    echo "       or at ~/.ssh/splash-updater. Ask your admin for the key." >&2
    exit 2
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <path/to/image.png>" >&2
    echo "" >&2
    echo "  Image must be exactly 1920x1080 and saved as PNG." >&2
    exit 2
fi
FILE="$1"

if [[ ! -f "$FILE" ]]; then
    echo "ERROR: file not found: $FILE" >&2
    exit 2
fi

# 1. PNG magic bytes (first 8 bytes must be 89 50 4E 47 0D 0A 1A 0A).
#    Reads with od for portability across macOS (which lacks xxd by default).
magic=$(od -An -N8 -tx1 "$FILE" | tr -d ' \n')
if [[ "$magic" != "89504e470d0a1a0a" ]]; then
    echo "ERROR: '$FILE' is not a PNG file." >&2
    echo "       Save your image as PNG (not JPG/HEIC/etc) and try again." >&2
    exit 2
fi

# 2. Dimensions. PNG IHDR chunk starts at byte 16 — 4 bytes width, 4 bytes height (big-endian).
#    Pure-shell parse for portability — no ImageMagick required on the volunteer's machine.
width=$(od -An -N4 -j16 -tu4 --endian=big "$FILE" 2>/dev/null | tr -d ' ' || true)
height=$(od -An -N4 -j20 -tu4 --endian=big "$FILE" 2>/dev/null | tr -d ' ' || true)

# macOS od has no --endian flag; build the value from individual bytes if needed.
if [[ -z "$width" || -z "$height" ]]; then
    bytes=$(od -An -N8 -j16 -tu1 "$FILE" | tr -d ' \n')
    # Re-read as eight space-separated decimals
    set -- $(od -An -N8 -j16 -tu1 "$FILE")
    width=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
    height=$(( $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 ))
fi

if [[ "$width" != "1920" || "$height" != "1080" ]]; then
    echo "ERROR: image is ${width}x${height}, but must be exactly 1920x1080." >&2
    echo "       Resize in your image editor and export as PNG." >&2
    exit 2
fi

echo "[splash-replace] file looks good (1920x1080 PNG)"
echo "[splash-replace] uploading to $HOST..."

# Pipe the file over SSH. The Pi-side ForceCommand will re-validate and
# refuse anything malformed. -o StrictHostKeyChecking=accept-new auto-
# trusts the Pi's host key on first contact (volunteers don't know what
# to do with the standard prompt).
chmod 600 "$KEY" 2>/dev/null || true
ssh -i "$KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "splash-updater@$HOST" < "$FILE"
