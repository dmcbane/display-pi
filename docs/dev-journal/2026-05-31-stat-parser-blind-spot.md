# Stat parser silently misreports "no active publishers"

**Date:** 2026-05-31
**Status:** Fixed
**Affects:** `diagnostics/judder.sh`, `diagnostics/parse_stat.py` (new),
`install/setup-kiosk.sh`, `tests/run-tests.sh`

## Symptom

`logs/monitor-5.log` from the 2026-05-23 service contained probe blocks
where the `SOURCE STREAM (ffprobe)` section reported full live-stream
metadata (h264 1920x1080 yuv420p 30/1 6.144 Mbps) while the very next
section, `ACTIVE PUBLISHERS (nginx-rtmp stat)`, in the same probe block
printed:

    app=live: no active streams
    (no active publishers on any stream)

No way to tell — from the captured log alone — whether the publisher
genuinely disconnected between the ffprobe call and the stat call (a few
hundred milliseconds), or whether the embedded XML parser silently
misread the XML the way the earlier monitor-loop `awk $3` regression
silently produced empty arithmetic operands (see
`2026-05-24` rprobe/vcgencmd entry).

## Root cause

Two compounding issues.

1. **No raw XML retained.** The embedded Python parser ran on the body
   in-process; the original XML was never written to disk. The operator
   had no way to confirm what nginx-rtmp actually emitted at the instant
   of the probe.
2. **Brittle XPath.** The probe parser used `app.findall('./live/stream')`
   — a strict two-level path. The stream-key parser used
   `root.findall('.//application/live/stream')`. Neither tolerated
   namespace declarations on the root, neither distinguished
   "publisher absent" from "live block present with subscribers waiting"
   (it would have helped to surface `<nclients>` in both cases), and
   neither produced a non-zero exit on parse failure — they printed a
   `(stat XML parse failed: ...)` line and returned 0, which under
   `set -u` propagated nothing useful to the caller.

## Fix

Extract the parser into a single shared helper, `diagnostics/parse_stat.py`,
with two modes (`probe` and `stream-key`). The helper:

- Prefers `defusedxml.ElementTree` over the stdlib parser (XXE and
  billion-laughs hardening). `install/setup-kiosk.sh` now installs
  `python3-defusedxml` as part of the package set; without it the helper
  falls back to stdlib (the /stat endpoint is loopback-only with
  `allow 127.0.0.1; deny all;`, so the threat model is bounded).
- Strips XML namespaces before searching so namespaced roots parse
  identically to bare ones.
- Searches `.//stream` under each `<application>` so any reasonable
  nesting (`rtmp/application/...` or `rtmp/server/application/...`)
  resolves.
- When an `<application>` has no `<stream>`, surfaces `<nclients>` from
  the `<live>` block so the operator can distinguish "publisher absent
  AND no subscribers" from "publisher absent BUT subscribers still
  waiting for it" — two very different operational states.
- Exits 2 with an error on stderr when the XML fails to parse. No
  silent success (CLAUDE.md: NEVER SWALLOW ERRORS).

`judder.sh probe` now writes the raw stat response to
`/tmp/judder-stat-${TS}.xml` and prints the path before the parsed
output. The next time a probe block claims "no active publishers" while
ffprobe disagrees, the raw bytes are right there to inspect.

`tests/run-tests.sh` drives the helper against eight realistic XML
fixtures: standard `<server>`-wrapped, bare-`<application>` (some
nginx-rtmp builds emit it), stream-key mismatch, publisher gone with
subscribers still waiting, subscribers-only stream, stream-key mode,
malformed XML, and namespaced root.

## Follow-up notes

- If the raw XML on a future probe confirms `nclients=0` and no
  `<stream>` while ffprobe simultaneously reads metadata, the
  publisher is genuinely transient — investigate at the ATEM side
  (network drops, keepalive) rather than the parser.
- `python3-defusedxml` is now a hard expectation. If a fresh Pi
  image fails to install it, the helper still functions on stdlib
  but the install log will flag the missing package.
