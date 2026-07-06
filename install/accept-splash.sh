#!/bin/bash
#
# accept-splash — Pi-side SSH ForceCommand for the splash-updater user.
#
# Invoked via the volunteer's SSH session. Reads an image (PNG, JPEG, GIF,
# or WebP) from stdin, validates it (format, 1920x1080 dimensions, max
# size, end-of-stream marker), stages it to a fixed directory, then calls
# the no-args sudo helper that copies the staged file into place and
# restarts the kiosk. The format travels to the installer via the staged
# filename's extension — the sudoers grant is argument-less, so the
# filename is the only channel.
#
# All output goes to the volunteer's terminal (stdout/stderr) — keep
# error messages actionable.

set -euo pipefail

MAX_BYTES=$((10 * 1024 * 1024))
STAGING_DIR="${SPLASH_STAGING_DIR:-/var/lib/splash-updater}"
INSTALLER=/usr/local/libexec/install-staged-splash

# Stage to a sibling tmpfile then mv into the canonical name so a partial
# upload never replaces a valid staged image.
mkdir -p "$STAGING_DIR"
tmp=$(mktemp "${STAGING_DIR}/.staged.XXXXXX")
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
# installed for render-status.sh); fall back to `file` if missing or if
# identify can't parse the input. The [0] frame selector keeps animated
# GIF/WebP to a single "W H FMT" line.
width=""
height=""
fmt=""
if command -v identify >/dev/null 2>&1; then
    read -r width height fmt < <(identify -format '%w %h %m' "${tmp}[0]" 2>/dev/null) || true
fi
if [[ -z "$fmt" ]]; then
    # Fallback: parse `file` output. Dimensions appear as ", 1920 x 1080"
    # (PNG/GIF) or ", 1920x1080" (JPEG/WebP); the leading ", " anchor skips
    # JPEG's "density 1x1" field.
    info=$(file -b "$tmp" 2>/dev/null || true)
    case "$info" in
        PNG\ image\ data*)  fmt=PNG ;;
        JPEG\ image\ data*) fmt=JPEG ;;
        GIF\ image\ data*)  fmt=GIF ;;
        RIFF*Web/P*)        fmt=WEBP ;;
    esac
    if [[ -n "$fmt" && "$info" =~ ,\ ([0-9]+)\ ?x\ ?([0-9]+) ]]; then
        width="${BASH_REMATCH[1]}"
        height="${BASH_REMATCH[2]}"
    fi
fi

case "$fmt" in
    PNG)  ext=png ;;
    JPEG) ext=jpg ;;
    GIF)  ext=gif ;;
    WEBP) ext=webp ;;
    *)
        echo "ERROR: input is not a PNG, JPEG, GIF, or WebP image (got: ${fmt:-unknown})" >&2
        echo "       Save your image in one of those formats and try again." >&2
        exit 2 ;;
esac
if [[ "$width" != "1920" || "$height" != "1080" ]]; then
    echo "ERROR: image must be 1920x1080 (got: ${width}x${height})" >&2
    echo "       Resize your image to exactly 1920x1080 and try again." >&2
    exit 2
fi

# `identify` and `file -b` parse only the header — a truncated upload still
# reports full dimensions. Require the format's end-of-stream marker so
# interrupted uploads are caught:
#   PNG  ends [len=0]["IEND"][CRC]; JPEG ends with EOI (ff d9);
#   GIF  ends with the trailer byte 0x3b (';');
#   WebP's RIFF header stores the payload size (bytes 4-7, little-endian,
#   which is the native order on both the Pi and x86) = file size - 8.
truncated=""
case "$fmt" in
    PNG)
        iend=$(tail -c 8 "$tmp" | head -c 4 | od -An -c | tr -d ' \n')
        [[ "$iend" == "IEND" ]] || truncated="no IEND chunk at end"
        ;;
    JPEG)
        eoi=$(tail -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')
        [[ "$eoi" == "ffd9" ]] || truncated="no EOI marker at end"
        ;;
    GIF)
        trailer=$(tail -c 1 "$tmp" | od -An -tx1 | tr -d ' \n')
        [[ "$trailer" == "3b" ]] || truncated="no trailer byte at end"
        ;;
    WEBP)
        riff_size=$(od -An -N4 -j4 -tu4 "$tmp" | tr -d ' ')
        (( riff_size + 8 == bytes )) || truncated="RIFF size doesn't match file size"
        ;;
esac
if [[ -n "$truncated" ]]; then
    echo "ERROR: ${fmt} file appears truncated (${truncated})" >&2
    echo "       The upload may have been interrupted. Try again." >&2
    exit 2
fi

# Validation passed — clear any stale staged file (the installer expects
# exactly one staged.*), move into place atomically, call the installer.
rm -f "$STAGING_DIR"/staged.*
mv "$tmp" "$STAGING_DIR/staged.$ext"
trap - EXIT
sudo /usr/local/libexec/install-staged-splash

echo "OK: splash replaced (1920x1080 ${fmt}, ${bytes} bytes)"
