# SRT Restreaming Design (MediaMTX)

Status: proposal / not implemented
Branch: `claude/srt-restreaming-design-vcHO8`

## Goal

Make the ATEM-originated live feed available as a **pull** SRT stream from the
display Pi, so 3–4 offsite consumers (with the expectation that the count may
grow) can connect when they choose. The kiosk display pipeline must remain
unaffected.

## Non-goals

- Transcoding (bitrate/codec change). Passthrough only.
- Outbound push to a specific destination. Consumers initiate.
- Public Internet streaming to unknown clients. Authenticated pull from known
  peers.

## Assumptions

- Single Pi 4 (2GB+) running the existing kiosk stack (Bookworm 64-bit Lite,
  cage + mpv, nginx-rtmp). No second Pi.
- ATEM Mini Pro continues to push RTMP once, to the display Pi, on port 1935.
- Source is H.264 video + AAC audio (ATEM default). Consumers accept MPEG-TS
  over SRT.
- Network ingress to the Pi for SRT is possible (LAN viewers, or a single
  UDP port forwarded on the site router for offsite callers).

## Architecture

```
                                 ┌────────────────────────────────────────┐
                                 │  Raspberry Pi 4 (displaypi)            │
                                 │                                        │
 ATEM Mini Pro ─── RTMP ────────▶│ nginx-rtmp :1935  application live     │
                                 │        │                               │
                                 │        ├─▶ mpv / cage (HDMI display)   │
                                 │        │                               │
                                 │        └─▶ push rtmp://127.0.0.1:1936 ─┼──▶ MediaMTX
                                 │                                        │      │
                                 │                           SRT :8890  ◀─┼──────┘
                                 │                           (listener)    │
                                 └────────────────────────────┬───────────┘
                                                              │
                                                     remote SRT callers
                                                     (up to N concurrent)
```

Two independent processes on the Pi:

1. **nginx-rtmp** — unchanged role for display; gains a `push` directive that
   relays the incoming stream to MediaMTX on localhost.
2. **MediaMTX** — receives the relayed RTMP, republishes as SRT with fan-out
   to N readers, handles auth.

The display path (nginx-rtmp → mpv) and the restream path (nginx-rtmp →
MediaMTX → SRT callers) share only the RTMP ingest. A MediaMTX crash cannot
affect mpv; an mpv crash cannot affect MediaMTX.

## Why MediaMTX (vs. ffmpeg exec, vs. srt-live-server)

- **ffmpeg `exec` from nginx-rtmp** is the simplest path, but each SRT output
  socket serves exactly one caller. Three viewers means three ffmpeg processes
  on three ports, with brittle lifecycle management.
- **srt-live-server (SLS)** does fan-out but is less maintained and
  SRT-only — no future flexibility (HLS, WebRTC) if needs change.
- **MediaMTX** is a single static Go binary, actively maintained, supports
  SRT / RTMP / HLS / WebRTC publish + read, handles fan-out, has a readable
  YAML config, and exposes optional Prometheus metrics that fit the existing
  `/tmp/kiosk-health.json` model.

## Resource budget (Pi 4)

Passthrough remux only:

| Component       | CPU (1 core of 4) | Memory | Notes                              |
|-----------------|-------------------|--------|------------------------------------|
| MediaMTX idle   | <1%               | ~20 MB | Goroutine scheduling overhead      |
| MediaMTX active | ~3–8%             | ~40 MB | RTMP demux + SRT mux, 4 readers    |
| Per reader      | marginal          | ~5 MB  | Ring-buffer + SRT send socket      |

Network: at 6 Mbps source, 4 readers = 24 Mbps egress. Well under the Pi 4's
gigabit NIC and within typical church upload bandwidth **only if** the site
has ≥25–30 Mbps upload. This is a site-networking precondition, not a Pi
limitation.

Thermal: negligible. No encoding.

## nginx-rtmp changes

In `install/nginx.conf`, inside `application live`:

```nginx
# Relay incoming publish to local MediaMTX for SRT fan-out.
# push is a no-op when MediaMTX is down; nginx-rtmp retries.
push rtmp://127.0.0.1:1936/live;
```

The display side is unaffected; mpv still pulls `rtmp://127.0.0.1:1935/live/<key>`
as today.

## MediaMTX configuration

Install by placing the upstream release binary at `/usr/local/bin/mediamtx`
plus a config at `/etc/mediamtx.yml` (preferred) or `/etc/mediamtx/mediamtx.yml`.

```yaml
# /etc/mediamtx.yml

logLevel: info
logDestinations: [stdout]

# --- RTMP ingest from localhost nginx-rtmp ---
rtmp: yes
rtmpAddress: 127.0.0.1:1936   # localhost-only; NOT publicly exposed
rtmpEncryption: "no"

# --- SRT publish (what pullers connect to) ---
srt: yes
srtAddress: :8890             # UDP, listener mode

# --- Disable everything we don't need ---
hls: no
webrtc: no
rtsp: no
api: no
metrics: no                   # enable later if we wire Prometheus

# --- Auth (see "Auth model" below) ---
authMethod: internal
authInternalUsers:
  - user: publisher
    pass: <redacted-publisher-pass>
    ips: [127.0.0.1/32]
    permissions:
      - action: publish
        path: live
  - user: viewer
    pass: <redacted-viewer-pass>
    ips: []                   # any source IP; rely on passphrase
    permissions:
      - action: read
        path: live

# --- Paths ---
paths:
  live:
    # Accept publishes from nginx-rtmp's push above.
    source: publisher
```

Key points:

- `rtmpAddress: 127.0.0.1:1936` keeps the localhost RTMP relay private; no
  second public RTMP endpoint exists.
- `srtAddress: :8890` is UDP. Default MediaMTX SRT port; change per local
  convention.
- No HLS / WebRTC / API / metrics by default. Enable deliberately later.
- nginx-rtmp's `push` sends to `rtmp://127.0.0.1:1936/live` — no stream key
  in URL. MediaMTX authenticates the publisher with user+pass.

## Auth model

Two separate credentials, both managed like `STREAM_KEY` today (Makefile
variable, injected into generated configs by `setup-kiosk.sh`):

1. **`MEDIAMTX_PUBLISHER_PASS`** — used by nginx-rtmp → MediaMTX push only.
   Never leaves the Pi.
2. **`MEDIAMTX_VIEWER_PASS`** — shared with the 3–4 SRT consumers.

SRT callers connect with a `streamid` of the form:

```
srt://<pi-public-host>:8890?passphrase=<MEDIAMTX_SRT_PASSPHRASE>&streamid=read:viewer:<MEDIAMTX_VIEWER_PASS>:live
```

- `passphrase` is SRT-level AES-128 encryption, orthogonal to MediaMTX auth.
  Both are required.
- `streamid` is parsed by MediaMTX as `<action>:<user>:<pass>:<path>`.
- Rotating `MEDIAMTX_VIEWER_PASS` requires editing `mediamtx.yml` and
  `systemctl restart mediamtx`; active callers will be kicked.

## systemd unit

`/etc/systemd/system/mediamtx.service`:

```ini
[Unit]
Description=MediaMTX (SRT restream broker)
After=network-online.target nginx.service
Wants=network-online.target
# NOT Requires= — MediaMTX should keep trying even if nginx is restarting.

[Service]
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx.yml
Restart=always
RestartSec=2
User=mediamtx
Group=mediamtx
# Needs to bind <1024? No — 8890 and 1936 are unprivileged.
AmbientCapabilities=
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
# stdout captured by journald
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Run as a dedicated unprivileged `mediamtx` user (created by
`setup-kiosk.sh`). No overlap with the `kiosk` user.

## Firewall / network

- **Inbound**: UDP 8890 from the Internet (or LAN) to the Pi. Requires one
  port forward on the site router if offsite viewers are expected.
- **Inbound**: no change to RTMP 1935 exposure; ATEM continues to publish as
  today.
- **Outbound**: none initiated by MediaMTX.

`ufw` rules if/when ufw is adopted:
```
ufw allow proto udp from <viewer-cidr> to any port 8890
```

## Failure modes and mitigations

| Failure                                | Effect on display       | Effect on restream      | Mitigation                                                       |
|----------------------------------------|-------------------------|-------------------------|------------------------------------------------------------------|
| MediaMTX crash / OOM                   | None                    | All viewers drop        | `Restart=always`; health check (below); review journald          |
| nginx-rtmp `push` target unreachable   | None (push is fire-and-retry) | Restream silent until MediaMTX back | nginx-rtmp retries `push` every few seconds automatically        |
| ATEM disconnects                       | Splash (existing)       | MediaMTX publisher disconnects; viewers drop | Existing `drop_idle_publisher 10s` propagates                     |
| SRT caller on lossy link               | None                    | Their session may stall / reconnect | `latency` tuning in caller URL (e.g. `?latency=1000`)            |
| Port 8890 unreachable (firewall drift) | None                    | No viewer can connect   | Add reachability probe to `diagnostics/health-monitor.sh`         |
| Upload bandwidth saturation            | None (RX unaffected)    | Viewers stutter         | Cap concurrent readers via MediaMTX `readUserLimit` if needed     |

## Health / observability integration

Extend `diagnostics/health-monitor.sh` to publish a `mediamtx` block in
`/tmp/kiosk-health.json`:

- `mediamtx.service_active` — systemd `is-active` result.
- `mediamtx.srt_port_listening` — `ss -uln sport = :8890` probe.
- `mediamtx.publisher_connected` — optional; requires enabling MediaMTX API
  (local bind) and querying `/v3/paths/get/live`.
- `mediamtx.readers` — optional; same API path returns reader count.

The existing mpv overlay can then show a small "restream OK / N viewers"
indicator if desired.

Log rotation: MediaMTX logs via journald — rotation handled by systemd.
No addition to `install/logrotate-kiosk` needed.

## Install-script integration

`install/setup-kiosk.sh` changes (sketch only):

1. Add a step `install_mediamtx()`:
   - Detect arch (`dpkg --print-architecture` → `arm64`).
   - Download pinned MediaMTX release from GitHub releases.
   - Verify SHA256 against a hash pinned in this repo.
   - Install binary to `/usr/local/bin/mediamtx`, owned root:root, mode 0755.
2. Add `create_mediamtx_user()` — `useradd -r -s /usr/sbin/nologin mediamtx`.
3. Generate `/etc/mediamtx.yml` from a template in `install/`, substituting
   `MEDIAMTX_PUBLISHER_PASS`, `MEDIAMTX_VIEWER_PASS`, `MEDIAMTX_SRT_PASSPHRASE`.
   These come from env / Makefile overrides, same pattern as `STREAM_KEY`.
4. Install `install/mediamtx.service`, enable it.
5. Patch `install/nginx.conf` template to include the `push` directive.

Secrets handling: credentials must NOT be committed. Options:

- Env vars passed to `setup-kiosk.sh`, same as `STREAM_KEY` today.
- Or: generate random values on first run, print once, store in
  `/etc/mediamtx.yml` (root-readable only).

Recommend generating on first run and printing — avoids secrets in shell
history or Makefile variables.

## Rollout plan

1. Implement in a feature branch. Keep nginx `push` behind an env toggle so
   the same `setup-kiosk.sh` can deploy the display-only config.
2. Stage on the dev Pi. Verify:
   - mpv still displays without hitches.
   - `ffplay 'srt://displaypi:8890?streamid=read:viewer:<pass>:live&passphrase=<pp>'`
     works from one LAN client.
   - Two concurrent LAN clients work.
   - Kill MediaMTX mid-stream — display unaffected; clients reconnect.
   - Kill ATEM mid-stream — splash returns; MediaMTX logs publisher drop.
3. Roll to production Pi during a non-service window.
4. Share `streamid` + passphrase + URL template with the initial 3–4 viewers.

## Open questions

- **SRT latency default.** MediaMTX defaults are reasonable (~200ms). Offsite
  viewers on residential Internet may want to override to 500–1000ms in their
  caller URL. Document in viewer instructions.
- **Single `path: live` vs. multiple.** Current design exposes one path
  matching the existing single-stream model. If future multi-camera ATEM-less
  use cases appear, paths become per-source.
- **Public hostname / DDNS.** Out of scope for this doc. Offsite pullers need
  a stable address for the Pi's WAN IP.
- **Metrics / API exposure.** Default off. If the health monitor wants path
  state, enable `api: yes` bound to `127.0.0.1` only.
- **Pi 4 RAM floor.** 2GB is sufficient per the budget above, but the
  existing kiosk already runs lean. Confirm on the current production Pi
  before assuming headroom.

## What this design does NOT do

- No transcoding tier for low-bandwidth viewers. If that's wanted later,
  revisit — likely a second Pi 5 dedicated to encoding, not this one.
- No recording. MediaMTX supports it; intentionally left off to keep the Pi's
  SD card out of the write path.
- No WebRTC / browser viewer. Adding it is a config flip later, not a
  redesign.
