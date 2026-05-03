# Splash stays up while a publisher is connected (stream-key mismatch)

**Date:** 2026-05-03
**Status:** Diagnostic infra in place; root cause is operator-side
(publisher's stream key)
**Affects:** `install/nginx.conf`, `install/setup-kiosk.sh`,
`diagnostics/judder.sh`

## Symptom

Pi shows splash, the operator says "the stream is live." A
`judder.sh probe` confirms there *is* a publisher attached to nginx —

```
--- active RTMP connections (port 1935) ---
ESTAB 0 0  192.168.0.106:1935  192.168.0.108:59723
```

— but mpv (and ffprobe in the probe itself) gets back

```
[rtmp @ ...] Server error: No such stream
rtmp://127.0.0.1/live/church242: Operation not permitted
```

So the publisher's TCP session is alive, but the named stream the
player asks for (`live/church242`) does not exist on the server.

## Root cause

nginx-rtmp's `application live { ... }` accepts *any* stream key under
that app — there is no key-level whitelist. The publisher had simply
configured a different key (e.g. `church2`, no trailing `42`), so it
was publishing to `live/church2` while the player was subscribing to
`live/church242`. The server happily kept both endpoints; they just
never met.

The probe couldn't distinguish "publisher connected to wrong key" from
"publisher connected but not yet sending data" because nothing in the
probe surfaced the *actual* key in use.

## Fix

Two-part diagnostic infrastructure (no code change to the player itself
— the player is doing the right thing by refusing to play a key that
doesn't exist):

1. **Expose nginx-rtmp's `rtmp_stat` module** on a localhost-only HTTP
   listener — `http://127.0.0.1:8080/stat` — that returns an XML dump
   of every active publisher and subscriber on every stream. Added to
   both `install/nginx.conf` and the heredoc-generated config in
   `install/setup-kiosk.sh`.

2. **`judder.sh probe` now queries `/stat`** and prints one line per
   active stream:

   ```
   app=live key=church2 pub=192.168.0.108 flashver='FMLE/3.0' bw_in=5000000 subs=0  *** MISMATCH: player expects key=church242
   ```

   The `*** MISMATCH` tag fires whenever an active key differs from the
   one in the probe's `STREAM_URL` (the same one the player uses), so
   the failure mode is unambiguous in the captured log.

## Operator remediation

When the probe shows a `MISMATCH`, either:

- Reconfigure the publisher (ATEM, OBS, etc.) to use `church242` as the
  stream key.
- Or, if the publisher's key is the source of truth for some reason,
  edit `install/player.sh` to match and `make deploy`.

## Lesson

`ESTAB on :1935` + `ffprobe: No such stream` is *not* a contradiction
in nginx-rtmp — it's the signature of a publisher on the wrong key.
The probe needs the stat endpoint to disambiguate; without it, the
right next step ("ask the operator to check the stream key") looks
like just one possibility among several.
