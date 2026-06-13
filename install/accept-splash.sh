#!/bin/bash
#
# accept-splash — Pi-side SSH ForceCommand for the splash-updater user.
#
# Invoked via the volunteer's SSH session. Reads a PNG from stdin,
# validates it (magic bytes, 1920x1080 dimensions, max size), stages it
# to a fixed path, then calls the no-args sudo helper that copies the
# staged file into place and restarts the kiosk.
#
# All output goes to the volunteer's terminal (stdout/stderr) — keep
# error messages actionable.

set -euo pipefail

MAX_BYTES=$((10 * 1024 * 1024))
STAGING="${SPLASH_STAGING_PATH:-/var/lib/splash-updater/staged.png}"
INSTALLER=/usr/local/libexec/install-staged-splash

# Stage to a sibling tmpfile then mv into the canonical name so a partial
# upload never replaces a valid staged image.
staging_dir=$(dirname "$STAGING")
mkdir -p "$staging_dir"
tmp=$(mktemp "${staging_dir}/.staged.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# Cap stdin to MAX_BYTES+1 so we can distinguish "exact size" from "over limit".
head -c $((MAX_BYTES + 1)) > "$tmp"
bytes=$(stat -c %s "$tmp")

if (( bytes == 0 )); then
    echo "ERROR: no data received on stdin (did you pipe a file?)" >&2
    exit 2
fi
if (( bytes > MAX_BYTES )); then
    echo "ERROR: file too large (>$(( MAX_BYTES / 1024 / 1024 )) MiB)" >&2
    exit 2
fi

# Validate format + dimensions. Prefer ImageMagick `identify` (already
# installed for render-status.sh); fall back to `file` if missing.
width=""
height=""
fmt=""
if command -v identify >/dev/null 2>&1; then
    read -r width height fmt < <(identify -format '%w %h %m' "$tmp" 2>/dev/null) || true
fi
if [[ -z "$fmt" ]]; then
    # Fallback: parse `file` output, e.g. "PNG image data, 1920 x 1080, ..."
    info=$(file -b "$tmp" 2>/dev/null || true)
    if [[ "$info" =~ ^PNG\ image\ data,\ ([0-9]+)\ x\ ([0-9]+) ]]; then
        fmt=PNG
        width="${BASH_REMATCH[1]}"
        height="${BASH_REMATCH[2]}"
    fi
fi

if [[ "$fmt" != "PNG" ]]; then
    echo "ERROR: input is not a PNG image (got: ${fmt:-unknown})" >&2
    echo "       Save your image as PNG and try again." >&2
    exit 2
fi
if [[ "$width" != "1920" || "$height" != "1080" ]]; then
    echo "ERROR: image must be 1920x1080 (got: ${width}x${height})" >&2
    echo "       Resize your image to exactly 1920x1080 and try again." >&2
    exit 2
fi

# `identify` and `file -b` both parse only the IHDR header — a 100-byte
# truncated PNG still looks like "PNG, 1920 x 1080" to them. Require an
# IEND chunk at the end of the file to catch truncated uploads.
# A valid PNG ends with: [4 bytes length=0][4 bytes "IEND"][4 bytes CRC]
iend=$(tail -c 8 "$tmp" | head -c 4 | od -An -c | tr -d ' \n')
if [[ "$iend" != "IEND" ]]; then
    echo "ERROR: PNG file appears truncated (no IEND marker at end)" >&2
    echo "       The upload may have been interrupted. Try again." >&2
    exit 2
fi

# Validation passed — move into place atomically and call the installer.
mv "$tmp" "$STAGING"
trap - EXIT
sudo /usr/local/libexec/install-staged-splash

echo "OK: splash.png replaced (1920x1080 PNG, ${bytes} bytes)"
