#!/bin/bash
#
# kiosk-config — safely edit /etc/default/kiosk, the kiosk's single config store.
#
# That one file holds STREAM_KEY, RTMP_APP, STREAM_URL, VOLUME, HDMI_MODE,
# SPLASH_DIR and the RTMP publish CIDRs. kiosk.service pulls it in through
# `EnvironmentFile=`, and player.sh sources it directly. A stray unquoted
# space or an unbalanced quote in there does not fail loudly at edit time — it
# fails at the NEXT BOOT, on a Sunday morning, as a black screen.
#
# So: edit a copy, prove the shell can source it, and only then install it over
# the real file. A rejected edit leaves the running config exactly as it was.
#
# Usage:
#   kiosk-config              # open the config in an editor
#   kiosk-config --show       # print it and exit
#
# Environment:
#   KIOSK_ENV_FILE   config path (default /etc/default/kiosk)
#   EDITOR / VISUAL  preferred editor (nano is declined — see below)

set -euo pipefail

ENV_FILE="${KIOSK_ENV_FILE:-/etc/default/kiosk}"

log()  { printf '\033[1;34m[kiosk-config]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[kiosk-config] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[kiosk-config] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Editing /etc/default/kiosk needs root; a temp copy under $HOME does not.
# Only reach for sudo when the target is actually out of reach, so the same
# script works unprivileged against a test/staging path.
if [[ -w "$ENV_FILE" ]] || { [[ ! -e "$ENV_FILE" ]] && [[ -w "$(dirname "$ENV_FILE")" ]]; }; then
    SUDO=()
else
    SUDO=(sudo)
fi

if [[ "${1:-}" == "--show" ]]; then
    [[ -e "$ENV_FILE" ]] || die "$ENV_FILE does not exist yet — run setup first."
    "${SUDO[@]}" cat "$ENV_FILE"
    exit 0
fi

# --- Editor selection -------------------------------------------------------
#
# micro first: it is modeless, shows its own keybindings at the bottom, and
# ctrl-s/ctrl-q do what everyone already expects — the right default for a
# volunteer who was handed an SSH session and a one-line instruction. vim and
# vi follow for anyone who'd rather have them.
#
# nano is declined even when it is what $EDITOR says. This is a project
# convention, not a judgment about the editor; micro fills the same niche here
# and is what the Pi is provisioned with.
EDITOR_CANDIDATES=(micro vim vi)

pick_editor() {
    local preferred="${VISUAL:-${EDITOR:-}}"
    if [[ -n "$preferred" ]]; then
        if [[ "$(basename "$preferred")" == "nano" ]]; then
            warn "\$EDITOR is nano; using micro instead (project convention)."
        elif command -v "$preferred" >/dev/null 2>&1 || [[ -x "$preferred" ]]; then
            printf '%s\n' "$preferred"
            return 0
        else
            warn "\$EDITOR '$preferred' not found; falling back."
        fi
    fi
    local candidate
    for candidate in "${EDITOR_CANDIDATES[@]}"; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

editor="$(pick_editor)" || die "No editor found. Install one: sudo apt install micro"

# --- Edit a copy ------------------------------------------------------------
work="$(mktemp)"
trap 'rm -f "$work" "$work.bak"' EXIT

if [[ -e "$ENV_FILE" ]]; then
    "${SUDO[@]}" cat "$ENV_FILE" > "$work"
else
    log "$ENV_FILE does not exist yet — starting a new one."
    printf '# Kiosk config — read by kiosk.service (EnvironmentFile=) and player.sh\n' > "$work"
fi
cp "$work" "$work.bak"

log "Editing $ENV_FILE with $editor ..."
"$editor" "$work"

if cmp -s "$work" "$work.bak"; then
    log "No changes made."
    exit 0
fi

# --- Validate before installing --------------------------------------------
#
# Two gates, because they catch different things:
#   bash -n     — parse errors (unbalanced quotes, stray parens)
#   subshell .  — anything that parses but explodes when sourced
# The subshell runs with the file's own contents; a config that only sets
# variables is inert, and anything that isn't inert has no business here.
if ! bash -n "$work" 2>/tmp/kiosk-config-err.$$; then
    warn "Rejected — the edited config is not valid shell:"
    sed 's/^/    /' "/tmp/kiosk-config-err.$$" >&2
    rm -f "/tmp/kiosk-config-err.$$"
    die "$ENV_FILE left unchanged."
fi
rm -f "/tmp/kiosk-config-err.$$"

if ! ( set +u; . "$work" ) >/dev/null 2>&1; then
    warn "Rejected — the edited config fails when sourced."
    die "$ENV_FILE left unchanged."
fi

# Every line that isn't a comment or blank must be a plain KEY=value
# assignment. kiosk.service's EnvironmentFile= parser accepts nothing else,
# and it ignores what it cannot parse SILENTLY — the exact failure mode this
# script exists to prevent.
bad_line=$(grep -vnE '^\s*(#|$)|^[A-Za-z_][A-Za-z0-9_]*=' "$work" | head -1 || true)
if [[ -n "$bad_line" ]]; then
    warn "Rejected — line ${bad_line%%:*} is not a KEY=value assignment:"
    printf '    %s\n' "${bad_line#*:}" >&2
    die "$ENV_FILE left unchanged."
fi

# --- Install ----------------------------------------------------------------
# root:root 0644 is what kiosk.service's EnvironmentFile= expects and what
# setup-kiosk.sh writes. The ownership flags need privilege, so they only go on
# when we actually have it — an unprivileged run against a test/staging path
# still gets the content and the mode.
if [[ ${#SUDO[@]} -gt 0 || $EUID -eq 0 ]]; then
    "${SUDO[@]}" install -m 0644 -o root -g root "$work" "$ENV_FILE"
else
    install -m 0644 "$work" "$ENV_FILE"
fi
log "Saved $ENV_FILE."

# Config changes only reach the display on a restart: kiosk.service reads
# EnvironmentFile= at start. Offer it, but only on a real terminal — a scripted
# caller gets the save and decides for itself.
if [[ -t 0 && "$ENV_FILE" == "/etc/default/kiosk" ]]; then
    read -r -p "Restart the kiosk now so the change takes effect? [y/N] " reply
    if [[ "$reply" =~ ^[Yy] ]]; then
        if command -v become-kiosk >/dev/null 2>&1; then
            become-kiosk systemctl --user restart kiosk.service
            log "Kiosk restarted."
        else
            warn "become-kiosk helper not found; restart manually."
        fi
    else
        log "Not restarted — the change applies at the next kiosk restart or reboot."
    fi
fi
