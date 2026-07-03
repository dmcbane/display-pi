#!/bin/bash
#
# ssh-copy-key.sh — install a PUBLIC key into the Pi's authorized_keys so the
# holder can SSH without a password. A portable, idempotent stand-in for
# ssh-copy-id: it appends the key only if it isn't already there, creates
# ~/.ssh with correct permissions, and never overwrites existing keys.
#
# Passwordless SSH is opt-in — a convenience for whoever wants it, never
# required (the Pi keeps accepting password logins unless you turn them off
# with `make ssh-password STATE=off`).
#
# Usage: ssh-copy-key.sh <host> [pubkey_path]
#   <host>         SSH destination, e.g. displaypi or rpi@192.168.0.106
#   [pubkey_path]  Public key to install. If omitted, uses $SSH_PUBKEY, else
#                  autodetects ~/.ssh/id_ed25519.pub then ~/.ssh/id_rsa.pub.
#
# Set DRY_RUN=1 to resolve+validate the key and print what would happen
# without connecting to the Pi.
set -euo pipefail

host="${1:-}"
if [[ -z "$host" ]]; then
    echo "usage: $(basename "$0") <host> [pubkey_path]" >&2
    exit 2
fi

# Resolve the public key: explicit arg > $SSH_PUBKEY > autodetect.
pubkey="${2:-${SSH_PUBKEY:-}}"
if [[ -z "$pubkey" ]]; then
    for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
        if [[ -f "$cand" ]]; then
            pubkey="$cand"
            break
        fi
    done
fi

if [[ -z "$pubkey" ]]; then
    echo "ERROR: no public key found. Pass one explicitly, set SSH_PUBKEY, or" >&2
    echo "       generate one with: ssh-keygen -t ed25519" >&2
    exit 1
fi
if [[ ! -f "$pubkey" ]]; then
    echo "ERROR: public key file not found: $pubkey" >&2
    exit 1
fi

key_line="$(< "$pubkey")"

# A public key line begins with a known key type. This guard is the safety
# rail against accidentally pointing at a PRIVATE key (which would leak it
# into authorized_keys) — private keys start with "-----BEGIN ...".
if [[ ! "$key_line" =~ ^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-) ]]; then
    echo "ERROR: '$pubkey' does not look like an SSH *public* key" >&2
    echo "       (expected it to start with e.g. ssh-ed25519). Did you point at a" >&2
    echo "       private key by mistake? Use the matching .pub file instead." >&2
    exit 1
fi

echo "Public key: $pubkey"
echo "Target:     $host  (~/.ssh/authorized_keys)"

# Remote side: create ~/.ssh with correct perms, then append the key only if
# absent. The key arrives on stdin so we never have to quote it into a command.
remote_script='
    set -e
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    key="$(cat)"
    if grep -qxF "$key" ~/.ssh/authorized_keys; then
        echo ALREADY_PRESENT
    else
        printf "%s\n" "$key" >> ~/.ssh/authorized_keys
        echo ADDED
    fi
'

if [[ "${DRY_RUN:-}" == "1" ]]; then
    echo "DRY_RUN: would append this key to $host:~/.ssh/authorized_keys (if absent):"
    echo "  $key_line"
    exit 0
fi

result="$(printf '%s\n' "$key_line" | ssh "$host" "$remote_script")"
case "$result" in
    ADDED)
        echo "Key installed. You can now log in without a password:  ssh $host"
        ;;
    ALREADY_PRESENT)
        echo "Key already present on $host — nothing to do."
        ;;
    *)
        echo "ERROR: unexpected response from $host: $result" >&2
        exit 1
        ;;
esac
