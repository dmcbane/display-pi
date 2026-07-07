# Changing a repo default doesn't change an already-provisioned Pi

**Date:** 2026-07-07
**Status:** Understood (working as designed); documented so it's not re-hit
**Affects:** `install/render-nginx-conf.sh`, `/etc/default/kiosk`, anything
sourced from the config store (`RTMP_APP`, `RTMP_ALLOW_PUBLISH_CIDRS`,
`STREAM_KEY`, `STREAM_URL`, `VOLUME`, `SPLASH_DIR`)

Follow-on to [2026-07-05](2026-07-05-provision-config-clobber.md). That change
made `/etc/default/kiosk` the single source of truth and gave it
explicit-override-wins / keep-existing-otherwise semantics. This note records
the flip side of that guarantee — the thing that bit me while tightening the
RTMP publish allow-list in v0.28.0.

## Symptom

Changed the default `RTMP_ALLOW_PUBLISH_CIDRS` in the repo from
`192.168.0.0/16 10.0.0.0/8` to the wired `192.168.0.0/24` (in
`render-nginx-conf.sh`, `setup-kiosk.sh`, and the `Makefile`), committed,
`make deploy`. Deploy reported "nginx config updated and reloaded" and exited
clean. But the **live** `/etc/nginx/nginx.conf` still had the old broad rules:

```
allow publish 192.168.0.0/16;
allow publish 10.0.0.0/8;
```

The security fix looked deployed but was not in effect.

## Root cause

`render-nginx-conf.sh` fills `RTMP_ALLOW_PUBLISH_CIDRS` from
`/etc/default/kiosk` **first**, and only falls back to the compiled-in default
when the env file doesn't set it:

```sh
[[ -n "${RTMP_ALLOW_PUBLISH_CIDRS:-}" ]] || \
    RTMP_ALLOW_PUBLISH_CIDRS="$(. "$ENV_FILE" 2>/dev/null; echo "${RTMP_ALLOW_PUBLISH_CIDRS:-}")"
RTMP_ALLOW_PUBLISH_CIDRS="${RTMP_ALLOW_PUBLISH_CIDRS:-192.168.0.0/24}"
```

This Pi was provisioned earlier with the old value **persisted** into
`/etc/default/kiosk`. So the persisted `192.168.0.0/16 10.0.0.0/8` won over the
new repo default on every render. This is exactly the keep-existing behavior
the 2026-07-05 change introduced — deploy must never silently revert an
operator's configured value — working correctly. The repo default only ever
applies on a **fresh** Pi (or one whose env file doesn't set the key).

The trap: a repo-level default change *reads like* a config change, but for
any already-provisioned Pi it is a no-op. Nothing warns you; the render
succeeds and reloads.

## Fix (on the Pi)

Update the source of truth, then re-render:

```sh
sudo sed -i 's#^RTMP_ALLOW_PUBLISH_CIDRS=.*#RTMP_ALLOW_PUBLISH_CIDRS="192.168.0.0/24"#' /etc/default/kiosk
sudo bash -c '/home/kiosk/display-pi/install/render-nginx-conf.sh \
    /home/kiosk/display-pi/install/nginx.conf /etc/default/kiosk > /etc/nginx/nginx.conf'
sudo nginx -t && sudo systemctl reload nginx
```

Or, using the normal pipeline, pass the override so setup rewrites the key:
`make setup RTMP_ALLOW_PUBLISH_CIDRS=192.168.0.0/24` (the Makefile forwards a
variable explicitly set on the command line, which overwrites the persisted
value). Then `make deploy` renders from the updated env.

**Verified live:** `allow publish 192.168.0.0/24; deny publish all;` in the
running config; template default and persisted value now match, so no future
deploy reverts it.

## Takeaway

Two questions to ask before assuming a repo change reached a running Pi:

1. **Is this value read from `/etc/default/kiosk`?** If yes, the repo default is
   the fresh-install fallback only — an already-provisioned Pi keeps its
   persisted value. Change the value *on the Pi* (or pass it as an explicit
   `make setup` override), not just in the repo.
2. **Did the deploy actually change the artifact?** "updated and reloaded" can
   mean "re-rendered to the same bytes." Grep the live file, don't trust the
   log line.

The persisted-config-wins design is correct and worth keeping — the cost is
that repo default changes to config-store keys are invisible to existing Pis
by design. Not a bug; a property to remember.
