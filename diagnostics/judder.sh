#!/bin/bash
#
# judder.sh — On-Pi toolkit for diagnosing live-stream judder.
#
# Designed for offline use at the venue. No internet required.
# Run on the Pi as the `kiosk` user (or via `sudo -i -u kiosk`).
#
# Subcommands:
#   probe       One-shot read-only diagnostic dump
#   monitor     Long-running sampler (Ctrl-C to stop)
#   tree        Print the decision tree / interpretation guide
#   list        List available player variants for A/B testing
#   variant N   Swap the live player to a variant. Ctrl-C restores.
#   restore     Force-restore the original player (safety net)
#
# All output goes to /tmp; nothing is sent over the network.

set -u

STREAM_URL="${STREAM_URL:-rtmp://127.0.0.1/live/church242}"
KIOSK_USER="${KIOSK_USER:-kiosk}"
PLAYER_LINK="/home/${KIOSK_USER}/bin/player.sh"
PLAYER_TARGET="$(readlink -f "$PLAYER_LINK" 2>/dev/null || echo "")"
PLAYER_LOG="/tmp/player.log"
TS="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

section() {
    printf '\n========== %s ==========\n' "$1"
}

require_kiosk() {
    if [[ "$(id -un)" != "$KIOSK_USER" ]]; then
        echo "ERROR: this subcommand must run as '$KIOSK_USER'." >&2
        echo "Try: sudo -i -u $KIOSK_USER $(readlink -f "$0") $*" >&2
        exit 2
    fi
}

kiosk_systemctl() {
    systemctl --user "$@"
}

# ---------------------------------------------------------------------------
# probe — one-shot read-only diagnostic dump.
# Safe to run while the kiosk is playing; does not touch the running mpv.
# ---------------------------------------------------------------------------
cmd_probe() {
    local out="/tmp/judder-probe-${TS}.log"
    {
        section "META"
        echo "host:    $(hostname)"
        echo "date:    $(date -Iseconds)"
        echo "uptime:  $(uptime)"
        echo "kernel:  $(uname -r)"
        echo "user:    $(id -un)"
        echo "stream:  $STREAM_URL"

        section "SOURCE STREAM (ffprobe)"
        if have ffprobe; then
            # r_frame_rate is the *declared* rate; avg_frame_rate is the *measured*.
            # 30000/1001 = 29.97; 30/1 = 30.000. The difference matters.
            timeout 10 ffprobe -v error \
                -select_streams v:0 \
                -show_entries stream=codec_name,width,height,r_frame_rate,avg_frame_rate,bit_rate,pix_fmt,profile \
                -of default=nw=0 \
                "$STREAM_URL" 2>&1 || echo "(ffprobe failed — stream live?)"
            echo
            timeout 10 ffprobe -v error \
                -select_streams a:0 \
                -show_entries stream=codec_name,sample_rate,channels,bit_rate \
                -of default=nw=0 \
                "$STREAM_URL" 2>&1 || true
        else
            echo "ffprobe not installed"
        fi

        section "ACTIVE PUBLISHERS (nginx-rtmp stat)"
        # The player hardcodes one stream key (church242). If a publisher is
        # connected to a *different* key, ffprobe above will say "No such
        # stream" while ss(8) shows an active TCP session on :1935 — exactly
        # the splash-stuck-while-stream-live failure mode. /stat lists every
        # active key and its publisher, so the mismatch is unambiguous.
        local stat_url="http://127.0.0.1:8080/stat"
        if have curl; then
            local stat_xml
            stat_xml=$(curl -fsS --max-time 3 "$stat_url" 2>&1) || {
                echo "(stat endpoint not reachable — older nginx.conf?  re-run setup or 'make deploy')"
                stat_xml=""
            }
            if [[ -n "$stat_xml" ]]; then
                # Per-stream summary: name (key), publisher addr, bytes in,
                # bw, # subscribers. One line per active stream.
                if have python3; then
                    EXPECTED_URL="$STREAM_URL" STAT_XML="$stat_xml" python3 <<'PY' || echo "(python3 parse failed)"
import os, xml.etree.ElementTree as ET
expected_url = os.environ['EXPECTED_URL']
expected_key = expected_url.rsplit('/', 1)[-1]
data = os.environ['STAT_XML']
try:
    root = ET.fromstring(data)
except ET.ParseError as e:
    print(f"(stat XML parse failed: {e})")
    raise SystemExit(0)
apps = root.findall('.//application')
if not apps:
    print("no <application> blocks (rtmp_stat returned empty)")
    raise SystemExit(0)
any_pub = False
for app in apps:
    app_name = (app.findtext('name') or '?').strip()
    streams = app.findall('./live/stream')
    if not streams:
        print(f"app={app_name}: no active streams")
        continue
    for s in streams:
        name = (s.findtext('name') or '?').strip()
        clients = s.findall('client')
        publisher = next((c for c in clients if c.find('publishing') is not None), None)
        n_subs = sum(1 for c in clients if c.find('publishing') is None)
        bw_in = (s.findtext('bw_in') or '0').strip()
        if publisher is not None:
            any_pub = True
            paddr = (publisher.findtext('address') or '?').strip()
            pflash = (publisher.findtext('flashver') or '').strip()
            if name == expected_key:
                tag = '  <-- matches player'
            else:
                tag = f'  *** MISMATCH: player expects key={expected_key}'
            print(f"app={app_name} key={name} pub={paddr} flashver={pflash!r} bw_in={bw_in} subs={n_subs}{tag}")
        else:
            print(f"app={app_name} key={name} (no publisher) subs={n_subs}")
if not any_pub:
    print("(no active publishers on any stream)")
PY
                else
                    echo "(python3 not available; raw XML at $stat_url)"
                fi
            fi
        else
            echo "curl not installed; cannot query $stat_url"
        fi

        section "DISPLAY MODE (current)"
        # /sys/class/drm shows what the kernel knows about connected outputs.
        for c in /sys/class/drm/card*-HDMI-A-*; do
            [[ -e "$c" ]] || continue
            echo "--- $(basename "$c") ---"
            echo "status:  $(cat "$c/status" 2>/dev/null)"
            echo "enabled: $(cat "$c/enabled" 2>/dev/null)"
            if [[ -r "$c/modes" ]]; then
                echo "available modes (top 8):"
                head -8 "$c/modes" 2>/dev/null | sed 's/^/  /'
            fi
        done
        echo
        if have wlr-randr; then
            echo "--- wlr-randr (active mode) ---"
            XDG_RUNTIME_DIR="/run/user/$(id -u $KIOSK_USER)" wlr-randr 2>&1 || echo "(wlr-randr failed — no Wayland session in this shell)"
        else
            echo "wlr-randr not installed (cannot read active mode from outside the cage session)"
        fi
        echo
        if have kmsprint; then
            echo "--- kmsprint ---"
            kmsprint 2>&1 | head -40
        fi

        section "THERMAL & THROTTLING"
        if have vcgencmd; then
            echo "temp:        $(vcgencmd measure_temp)"
            local thr
            thr=$(vcgencmd get_throttled)
            echo "throttled:   $thr"
            # Decode the throttled bits — non-zero = something happened.
            # bit 0  = under-voltage NOW
            # bit 1  = arm freq capped NOW
            # bit 2  = currently throttled
            # bit 3  = soft temp limit NOW
            # bit 16 = under-voltage occurred since boot
            # bit 17 = arm freq capped since boot
            # bit 18 = throttled since boot
            # bit 19 = soft temp limit since boot
            echo "  bits:      0=uv-now 1=cap-now 2=thr-now 3=soft-now 16=uv 17=cap 18=thr 19=soft"
            echo "arm clock:   $(vcgencmd measure_clock arm)"
            echo "v3d clock:   $(vcgencmd measure_clock v3d)"
            echo "h264 clock:  $(vcgencmd measure_clock h264)"
            echo "core volts:  $(vcgencmd measure_volts core)"
        else
            echo "vcgencmd not available"
        fi

        section "PLAYER LOG (recent drop / vsync / error lines)"
        if [[ -f "$PLAYER_LOG" ]]; then
            local count
            count=$(grep -ciE 'drop|vsync|miss|error|warn' "$PLAYER_LOG" 2>/dev/null || echo 0)
            echo "matching lines (lifetime): $count"
            echo "--- last 40 ---"
            grep -iE 'drop|vsync|miss|error|warn' "$PLAYER_LOG" 2>/dev/null | tail -40
        else
            echo "$PLAYER_LOG missing"
        fi

        section "MPV VERBOSE PROBE (20s, --vo=null, won't disturb playback)"
        # Open a parallel mpv against the same RTMP, decode-only, to capture
        # what mpv sees about the source. nginx-rtmp serves multiple subscribers.
        if have mpv; then
            local probe_log="/tmp/judder-mpv-probe-${TS}.log"
            timeout 20 mpv --vo=null --ao=null --no-config \
                --msg-level=all=v --really-quiet=no \
                --length=18 \
                "$STREAM_URL" >"$probe_log" 2>&1 || true
            echo "(full output at $probe_log)"
            echo "--- key lines ---"
            grep -iE 'fps|format:|video:|estimated|container|resolution|stream-fps|display' "$probe_log" 2>/dev/null \
                | head -40
        else
            echo "mpv not installed"
        fi

        section "PROCESSES & MEMORY"
        ps -eo pid,ppid,pcpu,pmem,etime,comm | grep -E 'mpv|cage|player\.sh|nginx|health-monitor' | grep -v grep
        echo
        free -m

        section "NETWORK"
        ip -4 -br addr show
        echo
        echo "--- active RTMP connections (port 1935) ---"
        ss -tn 2>/dev/null | awk 'NR==1 || /:1935 /'
        echo
        echo "(To measure jitter from ATEM: pick the ATEM IP above and run:"
        echo "   ping -c 100 -i 0.2 <atem-ip>"
        echo " then look at the mdev= value — under 2ms is fine.)"

        section "MPV VERSION"
        mpv --version 2>/dev/null | head -3 || echo "mpv missing"

        section "PLAYER FILE"
        echo "symlink: $PLAYER_LINK -> $PLAYER_TARGET"
        if [[ -f "$PLAYER_TARGET" ]]; then
            echo "mpv flags currently in use:"
            grep -E '^\s*--' "$PLAYER_TARGET" | sed 's/^/  /'
        fi

    } | tee "$out"
    echo
    echo "Saved: $out"
}

# ---------------------------------------------------------------------------
# monitor — sample state every N seconds for trend-watching during a service.
# ---------------------------------------------------------------------------
cmd_monitor() {
    local interval="${1:-10}"
    local out="/tmp/judder-monitor-${TS}.log"
    echo "Monitoring every ${interval}s; Ctrl-C to stop. Output: $out"
    echo "time              temp   throttled  arm-mhz  drops-since-start  mpv-cpu%"
    echo "time              temp   throttled  arm-mhz  drops-since-start  mpv-cpu%" > "$out"

    local start_drops=""
    while true; do
        local now temp thr arm drops mpv_cpu mpv_pid
        now=$(date +%H:%M:%S)
        temp=$(vcgencmd measure_temp 2>/dev/null | sed 's/temp=//; s/.C$//')
        thr=$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')
        arm=$(($(vcgencmd measure_clock arm 2>/dev/null | awk -F= '{print $2}') / 1000000))

        # Count "drop" mentions in player.log as a cheap drop counter.
        # GNU grep -c on a no-match (empty) log outputs "0" AND exits 1; a naive
        # `grep -c … || echo 0` therefore produces a 2-line "0\n0" that breaks
        # the arithmetic below. Set drops only on grep failure (missing file).
        drops=$(grep -ci 'drop' "$PLAYER_LOG" 2>/dev/null) || drops=0
        [[ -z "$start_drops" ]] && start_drops=$drops
        local delta=$((drops - start_drops))

        mpv_pid=$(pgrep -f 'mpv.*rtmp' | head -1)
        if [[ -n "$mpv_pid" ]]; then
            mpv_cpu=$(top -bn1 -p "$mpv_pid" 2>/dev/null | awk -v p="$mpv_pid" '$1==p {print $9}')
        else
            mpv_cpu="-"
        fi

        local line
        line=$(printf "%-17s %-6s %-10s %-8s %-18s %s" \
            "$now" "${temp}C" "$thr" "$arm" "$delta" "$mpv_cpu")
        echo "$line"
        echo "$line" >> "$out"
        sleep "$interval"
    done
}

# ---------------------------------------------------------------------------
# Variant management — temporarily replace /home/kiosk/bin/player.sh symlink
# with a modified copy. Ctrl-C / EXIT trap restores the symlink.
# ---------------------------------------------------------------------------
VARIANTS=(
    "default        Let mpv pick everything (no --video-sync, no --hwdec)"
    "audio-sync     --video-sync=audio (mpv default; explicit)"
    "vdrop          --video-sync=display-vdrop (drop dupe frames cleanly)"
    "no-hwdec       --hwdec=no (rules out Pi 4 v3d hwdec)"
    "drm-copy       --hwdec=drm-copy (alternate hwdec path)"
    "bigger-cache   --demuxer-readahead-secs=5 --demuxer-max-bytes=32MiB"
    "no-resample    Drop --video-sync=display-resample only"
    "verbose        Current settings + --msg-level=all=v (heavy log capture)"
)

cmd_list() {
    echo "Available variants (./judder.sh variant <name>):"
    printf '  %s\n' "${VARIANTS[@]}"
}

# Build a modified player.sh by patching the original mpv invocation.
# Returns the path to the new file.
build_variant() {
    local name="$1" src="$2" dst="$3"
    cp "$src" "$dst"

    case "$name" in
        default)
            # Strip every mpv-tuning flag we care about; let mpv decide.
            sed -i \
                -e 's|--video-sync=display-resample||' \
                -e 's|--hwdec=auto-safe||' \
                -e 's|--hr-seek=no||' \
                -e 's|--video-sync=display-resample \\||' \
                "$dst"
            ;;
        audio-sync)
            sed -i 's|--video-sync=display-resample|--video-sync=audio|' "$dst"
            ;;
        vdrop)
            sed -i 's|--video-sync=display-resample|--video-sync=display-vdrop|' "$dst"
            ;;
        no-hwdec)
            sed -i 's|--hwdec=auto-safe|--hwdec=no|' "$dst"
            ;;
        drm-copy)
            sed -i 's|--hwdec=auto-safe|--hwdec=drm-copy|' "$dst"
            ;;
        bigger-cache)
            sed -i \
                -e 's|--demuxer-max-bytes=8MiB|--demuxer-max-bytes=32MiB|' \
                -e 's|--demuxer-readahead-secs=2|--demuxer-readahead-secs=5|' \
                "$dst"
            ;;
        no-resample)
            sed -i 's|--video-sync=display-resample||' "$dst"
            ;;
        verbose)
            sed -i 's|--msg-level=all=warn|--msg-level=all=v|' "$dst"
            ;;
        *)
            echo "Unknown variant: $name" >&2
            return 1
            ;;
    esac
}

restore_player() {
    local repo_target="$1"
    if [[ -z "$repo_target" ]]; then
        echo "(no original target recorded; skipping restore)" >&2
        return 0
    fi
    echo
    echo "Restoring original player symlink → $repo_target"
    ln -sfn "$repo_target" "$PLAYER_LINK"
    kiosk_systemctl restart kiosk.service
    echo "Restored. Kiosk restarting."
}

cmd_variant() {
    local name="${1:-}"
    [[ -z "$name" ]] && { cmd_list; exit 1; }
    require_kiosk variant "$name"

    if [[ -z "$PLAYER_TARGET" || ! -f "$PLAYER_TARGET" ]]; then
        echo "ERROR: cannot locate player.sh via $PLAYER_LINK" >&2
        exit 2
    fi

    # Refuse to run if symlink already points somewhere unexpected (a previous
    # variant left in place). User should `restore` first.
    if [[ "$PLAYER_TARGET" == /tmp/* ]]; then
        echo "ERROR: $PLAYER_LINK already points at a variant ($PLAYER_TARGET)." >&2
        echo "       Run: $0 restore" >&2
        exit 2
    fi

    local variant_file="/tmp/player.sh.variant-${name}-${TS}"
    build_variant "$name" "$PLAYER_TARGET" "$variant_file" || exit 1
    chmod +x "$variant_file"

    echo "Variant built: $variant_file"
    echo "Diff vs original:"
    diff -u "$PLAYER_TARGET" "$variant_file" || true
    echo

    # Set up restore trap BEFORE swapping the symlink — guarantees we revert
    # even on crash / SIGTERM.
    trap "restore_player '$PLAYER_TARGET'" EXIT INT TERM HUP

    ln -sfn "$variant_file" "$PLAYER_LINK"
    echo "Symlink redirected. Restarting kiosk.service..."
    kiosk_systemctl restart kiosk.service

    echo
    echo "=========================================================="
    echo " Variant '$name' is now LIVE on screen."
    echo " Watch for judder; compare with baseline."
    echo " Press Ctrl-C here to restore the original player."
    echo "=========================================================="
    # Sleep forever; trap handles restore.
    while true; do sleep 60; done
}

cmd_restore() {
    require_kiosk restore
    # Best guess at the canonical target from the repo location.
    local default_target="/home/${KIOSK_USER}/display-pi/install/player.sh"
    local target="${1:-$default_target}"
    if [[ ! -f "$target" ]]; then
        echo "ERROR: $target does not exist; pass the correct path explicitly." >&2
        exit 2
    fi
    ln -sfn "$target" "$PLAYER_LINK"
    kiosk_systemctl restart kiosk.service
    echo "Restored: $PLAYER_LINK -> $target"
}

# ---------------------------------------------------------------------------
# stream-key — fast one-shot lookup of what stream key the publisher is
# currently using. For day-of-event triage when the kiosk is on splash and
# you need to decide: fix the publisher or hot-edit STREAM_URL on the Pi.
# Reads the same /stat endpoint as `probe`, but no other I/O.
# ---------------------------------------------------------------------------
cmd_stream_key() {
    local stat_url="http://127.0.0.1:8080/stat"
    local stat_xml
    stat_xml=$(curl -fsS --max-time 3 "$stat_url" 2>&1) || {
        echo "ERROR: stat endpoint not reachable at $stat_url" >&2
        echo "       (re-run setup or 'make deploy' to install nginx.conf with rtmp_stat)" >&2
        exit 1
    }
    if ! have python3; then
        echo "ERROR: python3 required to parse stat XML" >&2
        exit 1
    fi
    local expected_key="${STREAM_URL##*/}"
    EXPECTED_KEY="$expected_key" STAT_XML="$stat_xml" python3 <<'PY'
import os, sys, xml.etree.ElementTree as ET
expected = os.environ['EXPECTED_KEY']
try:
    root = ET.fromstring(os.environ['STAT_XML'])
except ET.ParseError as e:
    print(f"ERROR: stat XML parse failed: {e}", file=sys.stderr)
    raise SystemExit(2)
streams = root.findall('.//application/live/stream')
any_pub = False
for s in streams:
    name = (s.findtext('name') or '?').strip()
    bw_in = (s.findtext('bw_in') or '0').strip()
    for c in s.findall('client'):
        if c.find('publishing') is None:
            continue
        any_pub = True
        addr = (c.findtext('address') or '?').strip()
        flash = (c.findtext('flashver') or '').strip()
        if name == expected:
            tag = '  <-- matches player'
        else:
            tag = f'  *** MISMATCH: player expects key={expected}'
        print(f'key={name} pub={addr} flashver={flash!r} bw_in={bw_in}{tag}')
if not any_pub:
    print(f'(no active publishers; player expects key={expected})')
PY
}

# ---------------------------------------------------------------------------
# tree — interpretation guide. Read this at the venue with `less` or just run.
# ---------------------------------------------------------------------------
cmd_tree() {
cat <<'EOF'
JUDDER DECISION TREE
====================

Step 1 — Run `./judder.sh probe`. Open the output and answer:

  Q1. SOURCE FRAME RATE
      Look at the SOURCE STREAM section.
        r_frame_rate=30000/1001  → source is 29.97 fps
        r_frame_rate=30/1        → source is 30.000 fps
        r_frame_rate=60000/1001  → 59.94
        r_frame_rate=60/1        → 60.000

  Q2. DISPLAY REFRESH
      Look at DISPLAY MODE. The /sys/class/drm/.../modes file lists the
      *available* modes; the first one is usually the active one. If
      wlr-randr ran, its output is authoritative (look for "current").

  Q3. THROTTLING
      Look at THERMAL & THROTTLING.
        throttled=0x0           → fine
        throttled=0x50000       → under-voltage in past (cable / PSU)
        throttled=0x50005       → throttling NOW (cooling problem)
      Any non-zero high-bits hex digit (5, 6, 7, ...) = real issue.

  Q4. DROP / VSYNC LINES
      Look at PLAYER LOG and MPV VERBOSE PROBE.

------------------------------------------------------------------
Diagnosis A — frame-rate cadence mismatch
------------------------------------------------------------------
SYMPTOM: periodic skip every ~30-60 seconds, smooth between skips.
TRIGGER: source 29.97 + display 60.000 (or 30.000 + 59.94). The
         half-frame-per-minute drift forces a duplicate/skip on a
         predictable cadence that the eye locks onto.
FIX OPTIONS (pick the most achievable):
  1. Set ATEM to exactly 30.00 fps (not 29.97). ATEM Setup utility →
     Settings → Video Standard. "1080p30" on the ATEM is 29.97 by
     default in NTSC regions.
  2. Force HDMI to a specific mode (also fixes 4K-display preferred
     mode pulling the Pi to 3840x2160@30 with 1080p source). Under
     Bookworm KMS the legacy firmware knobs (hdmi_group, hdmi_mode,
     hdmi_drive) are IGNORED. Two cooperating layers do the work:
       - Kernel cmdline `video=HDMI-A-1:<mode>` in /boot/firmware/cmdline.txt
         (boot-time hint to DRM/KMS — best-effort).
       - Runtime `wlr-randr --output HDMI-A-1 --mode <mode>` invoked by
         player.sh's force_display_mode() — authoritative inside cage.
     Both read the same value: KIOSK_MODE in /etc/default/kiosk.

     CANONICAL MECHANISM (single source of truth — use this):
        # From your dev workstation:
        make hdmi-mode HDMI_MODE=1920x1080@30
        # Updates both cmdline.txt AND /etc/default/kiosk on the Pi.
        # The Pi will prompt-reboot. Verify with `make judder-probe`.

     To clear forcing:
        make hdmi-mode HDMI_MODE=none

     Verify the runtime layer landed:
        ssh kiosk@<pi> 'cat /etc/default/kiosk'   # KIOSK_MODE=... line
        ssh kiosk@<pi> 'wlr-randr'                # "(current)" mode

     Manual edit (only if `make hdmi-mode` is unavailable):
        sudoedit /boot/firmware/cmdline.txt
        # append, on the same single line (space-separated):
        video=HDMI-A-1:1920x1080@30
        sudoedit /etc/default/kiosk
        # add or replace inside the kiosk-setup marker block:
        KIOSK_MODE=1920x1080@30
        KIOSK_OUTPUT=HDMI-A-1
        # then: sudo reboot

     Other useful values: 1920x1080@60, 1920x1080@50, 1280x720@60.
     Append D after the rate (e.g. @60D) for double-clock CEA modes
     if the display gets confused; usually not needed.

     LAST-RESORT (only if both layers above can't pin the mode — e.g.
     panel ignores wlr-output-management): inject a custom EDID via
     `drm.edid_firmware=HDMI-A-1:edid/1080p.bin` on the kernel cmdline,
     with the blob installed at /lib/firmware/edid/1080p.bin. This
     bypasses TV EDID entirely. Document any use of this in the
     dev-journal so the next operator knows what's going on.
  3. Run cameras/ATEM at 60p if your cameras support it — 60→60 is
     a clean 1:1 lock, no cadence at all.

------------------------------------------------------------------
Diagnosis B — vsync / sync-mode interaction
------------------------------------------------------------------
SYMPTOM: constant low-amplitude shimmer; smooth motion looks
         vaguely "swimmy" or unsteady; no clear period.
TRIGGER: --video-sync=display-resample doing audio resampling work
         under cage/Wayland on the Pi 4. It's the right setting for
         awkward ratios but usually overkill (and stutter-prone) for
         clean 30→60 / 60→60 locks.
TRY (in order, watch for 30+ seconds each):
        ./judder.sh variant audio-sync
        ./judder.sh variant vdrop
        ./judder.sh variant default
If one is clearly smoother → bake into install/player.sh.

------------------------------------------------------------------
Diagnosis C — decode / hwdec issue
------------------------------------------------------------------
SYMPTOM: random short hitches; not periodic. mpv-cpu% in monitor
         spikes when the hitches happen. May coincide with high temp.
TRY:
        ./judder.sh variant drm-copy     # alternate hwdec path
        ./judder.sh variant no-hwdec     # software decode (slowest)
        ./judder.sh variant bigger-cache # absorb network jitter

If no-hwdec is smoother → the v3d hwdec is the problem.
If bigger-cache helps → upstream network/RTMP jitter.

------------------------------------------------------------------
Diagnosis D — thermal throttling
------------------------------------------------------------------
SYMPTOM: judder gets WORSE over the first 10-20 minutes of a service.
TRIGGER: throttled bits non-zero, especially bit 2 (throttling now).
FIX: improve cooling. Active fan or larger heatsink. Pi 4 sustained
     1080p decode runs hot in a closed enclosure.

------------------------------------------------------------------
Diagnosis E — cage/compositor overhead
------------------------------------------------------------------
SYMPTOM: nothing else explains it; mpv reports clean playback in
         verbose log; thermals fine.
TEST: temporarily try mpv directly on a TTY (no cage). This is
      manual — stop kiosk.service, switch to a TTY (Ctrl-Alt-F2),
      log in as kiosk, then:
        mpv --vo=drm --hwdec=auto-safe rtmp://127.0.0.1/live/church242
      If smooth → cage adds latency/jitter. Long-term fix would be
      moving mpv to drm directly without cage.

------------------------------------------------------------------
QUICK REFERENCE
------------------------------------------------------------------
./judder.sh probe              # one-shot diagnostic dump
./judder.sh monitor            # rolling sampler (Ctrl-C to stop)
./judder.sh monitor 5          # sample every 5s instead of 10
./judder.sh list               # show all variants
./judder.sh variant audio-sync # try the audio-sync variant live
./judder.sh restore            # safety net: force-restore symlink

Output files land in /tmp/judder-*. Copy them off with scp from
your laptop later.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    probe)      shift; cmd_probe "$@" ;;
    monitor)    shift; cmd_monitor "$@" ;;
    stream-key) cmd_stream_key ;;
    tree)       cmd_tree ;;
    list)       cmd_list ;;
    variant)    shift; cmd_variant "$@" ;;
    restore)    shift; cmd_restore "$@" ;;
    ""|-h|--help|help)
        cat <<EOF
judder.sh — on-Pi judder diagnostic toolkit

Usage:
  $0 probe              One-shot diagnostic dump to /tmp/judder-probe-*.log
  $0 monitor [secs]     Rolling sampler (default 10s interval)
  $0 stream-key         Fast: print the stream key any active publisher is using
  $0 tree               Print the decision tree (read at the venue)
  $0 list               List available player variants
  $0 variant <name>     Swap player to a variant; Ctrl-C restores
  $0 restore            Force-restore original player (safety net)

Start with: $0 probe   then   $0 tree
EOF
        ;;
    *)
        echo "Unknown subcommand: $1" >&2
        exit 1
        ;;
esac
