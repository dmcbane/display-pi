#!/bin/bash
#
# splash-store.sh — the ONE place that knows where kiosk splash images live.
#
# Every splash image on the Pi lives in a single folder, the "splash store":
#
#     /var/lib/kiosk-splash        (overridable via SPLASH_DIR in /etc/default/kiosk)
#
# player.sh rotates through it and the volunteer web manager uploads into it —
# those are the only two writers. Provisioning touches it from three different
# steps, and before this helper existed each step had its own opinion:
#
#   step 1  setup-kiosk.sh   wrote /home/kiosk/splash.png
#   step 2  deploy.sh        symlinked /home/kiosk/splash.d -> the repo working tree
#   step 3  kiosk-web-setup  created /var/lib/kiosk-splash, seeded it ONCE, and
#                            pointed SPLASH_DIR at it
#
# After step 3 the player read only the third location, so the first two were
# dead weight that kept accepting writes — repo images could differ from what
# was on screen with nothing to reveal the split. All three steps now call this
# script, so "where is it" has exactly one answer.
#
# Usage (also sourceable — sourcing defines the functions and runs nothing):
#   splash-store.sh path                        print the effective store path
#   splash-store.sh ensure [owner[:group]]      create it if absent
#   splash-store.sh seed <src_dir>              ensure, then copy images IF EMPTY
#   splash-store.sh migrate <legacy_dir> <legacy_image>
#                                               absorb + remove a pre-store layout
#
# Seeding is deliberately only-if-empty: once the store holds anything it
# belongs to the operator and the volunteers, and a deploy must not overwrite
# their slides. To change the shipped images on a live Pi, upload through the
# web manager (or clear the store and re-seed on purpose).
#
# Environment:
#   SPLASH_DIR       explicit override, wins over the config store
#   KIOSK_ENV_FILE   config store path (default /etc/default/kiosk)

set -euo pipefail

SPLASH_STORE_DEFAULT=/var/lib/kiosk-splash
KIOSK_ENV_FILE="${KIOSK_ENV_FILE:-/etc/default/kiosk}"

# The formats mpv can display as a still (animated gif/webp loop as video).
# Kept in one array so the seed/scan predicates cannot drift apart.
SPLASH_EXTS=(png jpg jpeg gif webp)

log() { printf '\033[1;34m[splash-store]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[splash-store] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# find(1) predicate for "is a splash image", built from SPLASH_EXTS.
_iname_args() {
    local first=1 ext
    printf '%s' '('
    for ext in "${SPLASH_EXTS[@]}"; do
        (( first )) || printf ' %s' '-o'
        printf ' -iname *.%s' "$ext"
        first=0
    done
    printf ' %s' ')'
}

# Resolve the store. An explicit SPLASH_DIR wins; otherwise the value persisted
# in the config store wins; the compiled-in default is the last resort. This
# order matters — the live /etc/default/kiosk is authoritative on a running Pi,
# and a repo default that disagrees with it is how images went missing before.
store_path() {
    if [[ -n "${SPLASH_DIR:-}" ]]; then
        printf '%s\n' "$SPLASH_DIR"
        return
    fi
    local configured=""
    if [[ -r "$KIOSK_ENV_FILE" ]]; then
        configured=$(grep -E '^SPLASH_DIR=' "$KIOSK_ENV_FILE" 2>/dev/null \
            | tail -1 | cut -d= -f2- | tr -d '"'"'"'' ) || true
    fi
    printf '%s\n' "${configured:-$SPLASH_STORE_DEFAULT}"
}

# True when the store holds at least one displayable image. This is the guard
# that makes seeding idempotent and non-destructive.
store_has_images() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    # shellcheck disable=SC2046 # _iname_args deliberately expands to find args
    find -L "$dir" -maxdepth 1 -type f $(_iname_args) -print -quit 2>/dev/null | grep -q .
}

# Create the store if it is missing. Ownership is applied only at creation:
# on an existing store the current owner is authoritative (kiosk-web takes it
# over at step 3, and a later deploy must not hand it back to kiosk).
store_ensure() {
    local dir="$1" owner="${2:-kiosk:kiosk}"
    if [[ -d "$dir" ]]; then
        return 0
    fi
    if [[ $EUID -eq 0 ]]; then
        install -d -o "${owner%%:*}" -g "${owner##*:}" -m 0755 "$dir"
    else
        # Unprivileged callers (the test suite, an operator poking at a temp
        # store) get the directory without the ownership step rather than a
        # spurious failure. Anything that needs the real /var/lib path is
        # invoked under sudo by its caller.
        mkdir -p "$dir"
    fi
    log "created splash store $dir"
}

# Copy the repo's shipped images in, but only into an empty store.
store_seed() {
    local dir="$1" src="$2"
    store_ensure "$dir"
    if store_has_images "$dir"; then
        log "$dir already holds images — leaving it alone."
        return 0
    fi
    if [[ ! -d "$src" ]]; then
        log "no seed source at $src — store left empty."
        return 0
    fi
    local owner group f n=0
    owner=$(stat -c '%U' "$dir")
    group=$(stat -c '%G' "$dir")
    while IFS= read -r -d '' f; do
        if [[ $EUID -eq 0 ]]; then
            # install(1) as root: the seed source usually sits under the SSH
            # user's 0700 home, which neither kiosk nor kiosk-web can traverse.
            install -o "$owner" -g "$group" -m 0644 "$f" "$dir/$(basename "$f")"
        else
            install -m 0644 "$f" "$dir/$(basename "$f")"
        fi
        n=$((n + 1))
    done < <(find -L "$src" -maxdepth 1 -type f $(_iname_args) -print0 2>/dev/null | sort -z)
    log "seeded $dir with $n image(s) from $src"
}

# Absorb a pre-store layout and delete it, so the Pi is left with exactly one
# image location. Called by deploy.sh on every run; a no-op once migrated.
store_migrate() {
    local legacy_dir="$1" legacy_image="${2:-}" dir
    dir="$(store_path)"

    if [[ -L "$legacy_dir" ]]; then
        # The old deploy layout: a symlink into the deployed repo working tree.
        # Unlink it — never recurse through it. Deleting "its contents" would
        # delete the repo's own images/splash.d.
        rm -f "$legacy_dir"
        log "removed legacy splash symlink $legacy_dir"
    elif [[ -d "$legacy_dir" ]]; then
        # A real folder from an even older layout may hold slides the operator
        # or a volunteer put there. Move them in (without overwriting anything
        # the store already has), then drop the folder.
        store_ensure "$dir"
        local f dest moved=0
        while IFS= read -r -d '' f; do
            dest="$dir/$(basename "$f")"
            if [[ -e "$dest" ]]; then
                log "keeping existing $dest (legacy copy discarded)"
                continue
            fi
            mv "$f" "$dest"
            moved=$((moved + 1))
        done < <(find "$legacy_dir" -maxdepth 1 -type f $(_iname_args) -print0 2>/dev/null | sort -z)
        rm -rf "$legacy_dir"
        log "migrated $moved image(s) from $legacy_dir into $dir"
    fi

    if [[ -n "$legacy_image" && -e "$legacy_image" ]]; then
        # The retired single-image fallback. It only earns a slot in the
        # rotation if the store would otherwise be empty; on a normal Pi the
        # rotation set already supersedes it.
        store_ensure "$dir"
        if ! store_has_images "$dir" && [[ -f "$legacy_image" && ! -L "$legacy_image" ]]; then
            mv "$legacy_image" "$dir/01-$(basename "$legacy_image")"
            log "promoted legacy $legacy_image into the store"
        else
            rm -f "$legacy_image"
            log "removed legacy fallback $legacy_image"
        fi
    fi
}

# Sourced (`. splash-store.sh`) → functions only. Executed → dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-path}"
    shift || true
    case "$cmd" in
        path)
            store_path
            ;;
        ensure)
            store_ensure "$(store_path)" "${1:-kiosk:kiosk}"
            ;;
        seed)
            [[ $# -ge 1 ]] || die "usage: splash-store.sh seed <src_dir>"
            store_seed "$(store_path)" "$1"
            ;;
        migrate)
            [[ $# -ge 1 ]] || die "usage: splash-store.sh migrate <legacy_dir> [legacy_image]"
            store_migrate "$1" "${2:-}"
            ;;
        *)
            die "unknown command '$cmd' (path|ensure|seed|migrate)"
            ;;
    esac
fi
