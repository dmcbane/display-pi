# SRT Restreaming Design (MediaMTX)

Status: implemented on branch `claude/srt-restreaming-design-vcHO8` (not
yet merged or deployed to production Pi).
Branch: `claude/srt-restreaming-design-vcHO8`

## Goal

Make the ATEM-originated live feed available as a **pull** SRT stream from the
display Pi, so 3–4 on-site LAN consumers (with the expectation that the count
may grow) can connect when they choose. The kiosk display pipeline must remain
unaffected.

## Scope

**LAN only for the initial rollout.** No port forwards, no DDNS, no WAN-facing
SRT listener. All pullers are on the same site network as the Pi. Extending
to offsite viewers later is a follow-up change (adds public hostname, viewer
latency guidance, and firewall review — explicitly out of scope here).

## Non-goals

- Transcoding (bitrate/codec change). Passthrough only.
- Outbound push to a specific destination. Consumers initiate.
- WAN / offsite / Internet access. LAN pullers only.

## Assumptions

- Single Pi 4 (8 GB, already on hand) running the existing kiosk stack
  (Bookworm 64-bit Lite, cage + mpv, nginx-rtmp). No second Pi.
- ATEM Mini Pro continues to push RTMP once, to the display Pi, on port 1935.
- Source is H.264 video + AAC audio (ATEM default). Consumers accept MPEG-TS
  over SRT.
- Pullers are on the site LAN — same IP range used by the existing RTMP
  `allow publish` CIDRs (`192.168.0.0/16`, `10.0.0.0/8`).

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
                                                       LAN SRT callers
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
  SRT / RTMP / HLS / WebRTC publish + read, handles fan-out, and has a
  readable YAML config. Its optional HTTP API / Prometheus metrics are left
  disabled (see MediaMTX HTTP API discussion below).

## Resource budget (Pi 4)

Passthrough remux only:

| Component       | CPU (1 core of 4) | Memory | Notes                              |
|-----------------|-------------------|--------|------------------------------------|
| MediaMTX idle   | <1%               | ~20 MB | Goroutine scheduling overhead      |
| MediaMTX active | ~3–8%             | ~40 MB | RTMP demux + SRT mux, 4 readers    |
| Per reader      | marginal          | ~5 MB  | Ring-buffer + SRT send socket      |

Network: at 6 Mbps source, 4 readers = 24 Mbps egress over the LAN. Trivial
on the Pi 4's gigabit NIC; site WAN upload is irrelevant since viewers are
on-LAN.

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
        path: <STREAM_KEY>
  - user: viewer
    pass: <redacted-viewer-pass>
    ips: [192.168.0.0/16, 10.0.0.0/8]  # LAN only — mirrors nginx RTMP ACL
    permissions:
      - action: read
        path: <STREAM_KEY>

# --- Paths ---
paths:
  <STREAM_KEY>:
    # Accept publishes from nginx-rtmp's push above.
    source: publisher
```

Key points:

- `rtmpAddress: 127.0.0.1:1936` keeps the localhost RTMP relay private; no
  second public RTMP endpoint exists.
- `srtAddress: :8890` is UDP. Default MediaMTX SRT port; change per local
  convention.
- No HLS / WebRTC / API / metrics by default. Enable deliberately later.
- **Path name equals `STREAM_KEY`.** nginx-rtmp's `push` inherits the source
  stream name (e.g. `church242`) and publishes it to MediaMTX under that
  name, so the MediaMTX path must match. `setup-kiosk.sh` substitutes
  `__MEDIAMTX_STREAM_PATH__` in the template with the active `STREAM_KEY`
  at first run.

## Auth model

Two credentials, both generated on first run by `setup-kiosk.sh` and written
to a root-only crib sheet at `/etc/mediamtx-credentials.txt`:

1. **`MEDIAMTX_PUBLISHER_PASS`** — used by nginx-rtmp → MediaMTX push only.
   Never leaves the Pi.
2. **`MEDIAMTX_VIEWER_PASS`** — shared with the 3–4 SRT consumers.

SRT callers connect with a `streamid` of the form:

```
srt://displaypi.local:8890?streamid=read:viewer:<MEDIAMTX_VIEWER_PASS>:<STREAM_KEY>
```

Host resolution uses whatever already works on the LAN (mDNS `displaypi.local`,
DHCP-assigned hostname, or a static IP). No DDNS / public hostname needed.

- `streamid` is parsed by MediaMTX as `<action>:<user>:<pass>:<path>`.
- **No separate SRT transport passphrase.** MediaMTX internal auth
  (user+pass via `streamid`) plus the LAN-CIDR `ips:` allowlist are
  sufficient for the LAN-only scope. Adding `?passphrase=…` AES-128 on
  top is a later hardening step if/when the scope expands offsite.
- Rotating `MEDIAMTX_VIEWER_PASS` means editing `/etc/mediamtx.yml` and
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

- **Inbound**: UDP 8890 from LAN CIDRs only. No WAN port forward — this is
  enforced both by the absence of a router rule and by MediaMTX's per-user
  `ips:` allowlist in the config above.
- **Inbound**: no change to RTMP 1935 exposure; ATEM continues to publish as
  today.
- **Outbound**: none initiated by MediaMTX.

If/when `ufw` is adopted on the Pi:
```
ufw allow proto udp from 192.168.0.0/16 to any port 8890
ufw allow proto udp from 10.0.0.0/8    to any port 8890
```

## Failure modes and mitigations

| Failure                                | Effect on display       | Effect on restream      | Mitigation                                                       |
|----------------------------------------|-------------------------|-------------------------|------------------------------------------------------------------|
| MediaMTX crash / OOM                   | None                    | All viewers drop        | `Restart=always`; health check (below); review journald          |
| nginx-rtmp `push` target unreachable   | None (push is fire-and-retry) | Restream silent until MediaMTX back | nginx-rtmp retries `push` every few seconds automatically        |
| ATEM disconnects                       | Splash (existing)       | MediaMTX publisher disconnects; viewers drop | Existing `drop_idle_publisher 10s` propagates                     |
| SRT caller on flaky Wi-Fi              | None                    | Their session may stall / reconnect | Wired preferred; MediaMTX default latency (~200ms) is fine on LAN |
| Port 8890 unreachable (firewall drift) | None                    | No viewer can connect   | Add reachability probe to `diagnostics/health-monitor.sh`         |
| LAN switch saturation                  | None (RX unaffected)    | Viewers stutter         | Cap concurrent readers via MediaMTX `readUserLimit` if needed     |

## Health / observability integration

Extend `diagnostics/health-monitor.sh` to publish a `mediamtx` block in
`/tmp/kiosk-health.json`:

- `mediamtx.service_active` — `systemctl is-active mediamtx`.
- `mediamtx.srt_port_listening` — `ss -uln sport = :8890` probe.

That's the full default surface. Publisher-connected / reader-count fields
are deferred along with the API (see "MediaMTX HTTP API discussion" below);
if they're wanted later they become a two-line addition.

Log rotation: MediaMTX logs via journald — rotation handled by systemd.
No addition to `install/logrotate-kiosk` needed.

## Install-script integration

Implemented in `install/setup-kiosk.sh`. Four new functions, called from
`main()` immediately after `configure_nginx_rtmp`:

1. `create_mediamtx_user` — `useradd --system --no-create-home
   --shell /usr/sbin/nologin mediamtx`. Idempotent.
2. `install_mediamtx` — detect arch via `dpkg --print-architecture`, map to
   the MediaMTX release asset suffix, download the tarball and
   `checksums.sha256` from the pinned release, verify with `sha256sum -c`,
   install to `/usr/local/bin/mediamtx`. Skip if the installed binary
   already reports the pinned version.
3. `configure_mediamtx` — render `/etc/mediamtx.yml` from
   `install/mediamtx.yml` template, substituting generated credentials and
   the active `STREAM_KEY`. **Leaves an existing `/etc/mediamtx.yml`
   untouched** so credentials stay stable across re-runs. Also writes the
   crib sheet `/etc/mediamtx-credentials.txt` (root-only, 0600).
4. `install_mediamtx_service` — drop `install/mediamtx.service` into
   `/etc/systemd/system/`, `daemon-reload`, enable + start.

`install/nginx.conf` (and the heredoc in `configure_nginx_rtmp`) gained:

```nginx
push rtmp://127.0.0.1:1936/live;
```

`dev/deploy.sh` copies `install/mediamtx.service` into place on each deploy
(with `daemon-reload` + restart on change) but deliberately does NOT touch
`/etc/mediamtx.yml` — the live config holds generated secrets and is
owned by `setup-kiosk.sh`. Template changes are picked up only on the next
setup-kiosk.sh re-run.

Secrets handling: the crib sheet at `/etc/mediamtx-credentials.txt` is the
canonical source for sharing the viewer pass + URL template. Credentials
are generated with `tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32`; no
secrets are ever written to the repo.

## Rollout plan

1. `make check` on workstation (tests verify config and templates).
2. `make deploy` to dev Pi.
3. SSH to dev Pi, run `install/setup-kiosk.sh` once to bootstrap MediaMTX +
   generate credentials.
4. Verify:
   - `systemctl status mediamtx` shows active (running).
   - `sudo cat /etc/mediamtx-credentials.txt` — grab viewer pass + URL.
   - mpv still displays the ATEM stream without hitches.
   - `ffplay 'srt://<pi-ip>:8890?streamid=read:viewer:<pass>:church242'`
     works from one LAN client.
   - Two to four concurrent LAN clients work.
   - Kill MediaMTX mid-stream — display unaffected; clients reconnect
     when the service comes back.
   - Kill ATEM mid-stream — splash returns; MediaMTX logs publisher drop,
     SRT viewers see the connection close.
5. Roll to production Pi during a non-service window.
4. Share `streamid` + passphrase + URL template with the initial 3–4 viewers.

## Resolved decisions

- **Public hostname / DDNS — not needed.** LAN-only scope. Use existing LAN
  name resolution (mDNS / DHCP hostname / static IP).
- **SRT latency default — keep MediaMTX default (~200 ms).** LAN RTT is sub-ms
  and loss is negligible, so no per-viewer latency tuning is required.
  Document the caller URL template once and move on.
- **MediaMTX HTTP API — off by default.** Discussed below.
- **Single `path: live`.** One path covers the single-camera ATEM model today.
  Even the "dream" ceiling is one current stream plus at most two additional
  concurrent streams, which stays well within MediaMTX's capabilities on this
  hardware — adding more paths later is a config-only change, not a redesign.
- **Pi 4 RAM floor — resolved.** Production Pis are 8 GB. The ~40 MB MediaMTX
  footprint is a rounding error; no RAM-pressure concern.

### MediaMTX HTTP API discussion

MediaMTX can expose an HTTP API (default `127.0.0.1:9997`) that reports path
state, connected publishers, and reader counts — plus `/metrics` in Prometheus
format if `metrics: yes` is set.

What it buys us:

- A clean way for `diagnostics/health-monitor.sh` to answer "is the publisher
  connected?" and "how many viewers are currently pulling?" without parsing
  MediaMTX logs.
- A natural hook for the mpv overlay to show "restream: N viewers" alongside
  the existing status line.
- Future-proofing if someone later wants a small status web page or Grafana
  dashboard.

What it costs:

- One more HTTP listener on the Pi. Trivial CPU, but another moving part.
- One more thing to get wrong in config (accidentally binding `0.0.0.0` and
  exposing path/reader state to the LAN).
- Slight config churn — `api:` and `metrics:` keys, a systemd check that the
  bind address stays local.
- If the API is wired into the health monitor, a MediaMTX upgrade that shifts
  API routes (v3 → v4) becomes a correctness problem for the overlay.

Given the user's stated expectation ("not likely to use"), the design defaults
to **API off / metrics off**. The substitutes are:

- `systemctl is-active mediamtx` — covers "is the broker alive".
- `ss -uln sport = :8890` — covers "is the SRT port open".
- `journalctl -u mediamtx --since ...` — covers publisher/reader events on
  demand, since MediaMTX logs connect/disconnect at info level.

That gives the health monitor enough signal for the existing overlay model
without standing up another listener. If viewer-count visibility becomes
interesting later, enabling the API is a two-line config change:

```yaml
api: yes
apiAddress: 127.0.0.1:9997
```

and a `curl -s http://127.0.0.1:9997/v3/paths/get/live | jq …` in the health
script. That upgrade path stays cheap; no reason to pre-build it now.

## Open questions

- **Offsite viewers (deferred).** When/if LAN-only scope expands, revisit:
  public hostname, WAN port forward, per-viewer latency guidance (500–1000 ms
  is typical for residential links), and whether the LAN-CIDR allowlist in
  `ips:` should be replaced by per-user credentials scoped to specific peer
  IPs.

## What this design does NOT do

- No transcoding tier for low-bandwidth viewers. If that's wanted later,
  revisit — likely a second Pi 5 dedicated to encoding, not this one.
- No recording. MediaMTX supports it; intentionally left off to keep the Pi's
  SD card out of the write path.
- No WebRTC / browser viewer. Adding it is a config flip later, not a
  redesign.
