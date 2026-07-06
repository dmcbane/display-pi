#!/bin/bash
#
# splash-replace — volunteer-facing script (macOS/Linux).
#
# Replaces the splash image on the church-display Pi. Validates the file
# locally first (so an obviously-wrong file fails fast with a clear
# message), then uploads via SSH to the kiosk. The Pi re-validates on
# arrival and refuses to install anything that isn't a 1920x1080 PNG,
# JPEG, GIF, or WebP.
#
# Usage:
#   splash-replace.sh <path/to/image>       (PNG, JPEG, GIF, or WebP)
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
    echo "Usage: $0 <path/to/image>" >&2
    echo "" >&2
    echo "  Image must be exactly 1920x1080, saved as PNG, JPEG, GIF, or WebP." >&2
    exit 2
fi
FILE="$1"

if [[ ! -f "$FILE" ]]; then
    echo "ERROR: file not found: $FILE" >&2
    exit 2
fi

# 1. Detect the format from magic bytes (first 12 bytes cover all four:
#    PNG 89504e47..., JPEG ffd8ff, GIF "GIF87a"/"GIF89a", WebP is
#    "RIFF"<4-byte size>"WEBP"). Reads with od for portability across
#    macOS (which lacks xxd by default).
magic=$(od -An -N12 -tx1 "$FILE" | tr -d ' \n')
fmt=""
case "$magic" in
    89504e470d0a1a0a*)           fmt=PNG ;;
    ffd8ff*)                     fmt=JPEG ;;
    474946383761*|474946383961*) fmt=GIF ;;
    52494646????????57454250)    fmt=WEBP ;;
esac
if [[ -z "$fmt" ]]; then
    echo "ERROR: '$FILE' is not a PNG, JPEG, GIF, or WebP file." >&2
    echo "       Save your image in one of those formats (not HEIC/BMP/etc)" >&2
    echo "       and try again." >&2
    exit 2
fi

# 2. Dimensions — pure-shell header parse where the format makes that easy
#    (PNG and GIF have fixed-offset dimension fields; JPEG/WebP don't, so
#    for those the Pi-side check is the gatekeeper). No ImageMagick
#    required on the volunteer's machine.
width=""
height=""
case "$fmt" in
    PNG)
        # PNG IHDR chunk starts at byte 16 — 4 bytes width, 4 bytes height (big-endian).
        width=$(od -An -N4 -j16 -tu4 --endian=big "$FILE" 2>/dev/null | tr -d ' ' || true)
        height=$(od -An -N4 -j20 -tu4 --endian=big "$FILE" 2>/dev/null | tr -d ' ' || true)
        # macOS od has no --endian flag; build the value from individual bytes if needed.
        if [[ -z "$width" || -z "$height" ]]; then
            set -- $(od -An -N8 -j16 -tu1 "$FILE")
            width=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
            height=$(( $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 ))
        fi
        ;;
    GIF)
        # GIF logical screen size at bytes 6-9: u16 width, u16 height (little-endian).
        set -- $(od -An -N4 -j6 -tu1 "$FILE")
        width=$(( $1 + $2 * 256 ))
        height=$(( $3 + $4 * 256 ))
        ;;
esac

if [[ -n "$width" ]]; then
    if [[ "$width" != "1920" || "$height" != "1080" ]]; then
        echo "ERROR: image is ${width}x${height}, but must be exactly 1920x1080." >&2
        echo "       Resize in your image editor and try again." >&2
        exit 2
    fi
    echo "[splash-replace] file looks good (1920x1080 $fmt)"
else
    echo "[splash-replace] file looks like a $fmt image; the display will"
    echo "[splash-replace] verify the 1920x1080 size when it arrives."
fi

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
