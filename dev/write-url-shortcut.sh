#!/bin/bash
#
# write-url-shortcut.sh — write cross-platform "open this URL" shortcut files.
#
# Emits two clickable shortcut files for a single URL into the current
# directory, so a non-technical volunteer can just double-click on whatever
# machine they have:
#   <basename>.webloc   macOS (an Apple plist)
#   <basename>.url      Windows / Linux (an [InternetShortcut])
#
# Used by `make volunteer-web-url` to produce the volunteer web-manager
# shortcut and a reference shortcut to the docs site.
#
# Usage: write-url-shortcut.sh <url> <basename>
#   <url>       the URL the shortcuts point at
#   <basename>  output filename stem (without extension)
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $(basename "$0") <url> <basename>" >&2
    exit 2
fi

url="$1"
name="$2"

if [[ -z "$url" || -z "$name" ]]; then
    echo "ERROR: both <url> and <basename> must be non-empty" >&2
    exit 2
fi

# macOS .webloc — a property list with the URL.
printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>URL</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' \
    "$url" > "${name}.webloc"

# Windows / Linux .url — an INI-style InternetShortcut.
printf '[InternetShortcut]\nURL=%s\n' "$url" > "${name}.url"

echo "wrote ${name}.webloc and ${name}.url -> ${url}"
