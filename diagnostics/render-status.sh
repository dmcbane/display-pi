#!/bin/bash
#
# render-status.sh — Generate a diagnostic status PNG for kiosk display
#
# Checks system health and renders results as a fullscreen PNG that mpv
# can display. Each check gets a colored indicator visible from across
# the room: green = OK, yellow = warning, red = critical.
#
# Checks run concurrently (each in a background job) so total latency is
# the slowest single check (~5s ffprobe timeout) instead of the sum of
# all of them — this script sits on the boot path via assess.sh.
#
# Usage: render-status.sh [output.png]
# Default output: /tmp/kiosk-status.png

set -euo pipefail

OUTPUT="${1:-/tmp/kiosk-status.png}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Stream the kiosk player subscribes to. Must stay in step with player.sh —
# both default to setup-kiosk.sh's default (app=live, key=restoration) and
# both honor the same env override (/etc/default/kiosk via kiosk.service),
# so the screen reports what the player is actually configured to show.
STREAM_URL="${STREAM_URL:-rtmp://127.0.0.1/live/restoration}"
STREAM_KEY="${STREAM_URL##*/}"
_stream_path="${STREAM_URL#*://}"
_stream_path="${_stream_path#*/}"
STREAM_APP="${_stream_path%/*}"
# nginx rtmp_stat endpoint (loopback-only, see install/nginx.conf) — lists
# every publisher actually connected, whatever key they are pushing to.
STAT_URL="${STAT_URL:-http://127.0.0.1:8080/stat}"
WIDTH=1920
HEIGHT=1080
FONT="DejaVu-Sans"
FONT_SIZE=28
HEADING_SIZE=42
LINE_HEIGHT=44
MARGIN_TOP=80
MARGIN_LEFT=100

# Colors for status indicators
COLOR_OK="green"
COLOR_WARN="yellow"
COLOR_FAIL="red"
COLOR_TEXT="white"
COLOR_BG="black"
COLOR_HEADING="#00aaff"

# ---------------------------------------------------------------------------
# Health checks — each prints "STATUS|label|detail"
# STATUS is one of: OK, WARN, FAIL
# ---------------------------------------------------------------------------

check_hostname() {
    local hn
    hn=$(hostname)
    echo "OK|Hostname|${hn}"
}

check_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$ip" ]]; then
        echo "FAIL|Network|No IP address assigned"
    else
        echo "OK|Network|${ip}"
    fi
}

check_gateway() {
    # Many home routers drop ICMP — presence of a default route is what
    # matters for RTMP ingest (ATEM on same LAN).
    if ip route show default 2>/dev/null | grep -q default; then
        local gw
        gw=$(ip route show default | awk '{print $3; exit}')
        echo "OK|Gateway|${gw}"
    else
        echo "FAIL|Gateway|No default route"
    fi
}

# Link quality: detects a long/bad cable negotiating down to 100Mb/s or
# accumulating RX errors. Uses /sys/class/net (no root / ethtool needed).
check_link() {
    local iface speed duplex carrier
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$iface" ]]; then
        echo "WARN|Link|No active interface"
        return
    fi

    carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)
    if [[ "$carrier" != "1" ]]; then
        echo "FAIL|Link|${iface} carrier down"
        return
    fi

    speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || echo "?")
    duplex=$(cat "/sys/class/net/${iface}/duplex" 2>/dev/null || echo "?")

    local status="OK"
    local detail="${iface} @ ${speed}Mb/s ${duplex}"
    # Gigabit interface that negotiated down suggests cable issues
    if [[ "$speed" != "1000" && "$speed" != "?" ]]; then
        status="WARN"
        detail="${iface} @ ${speed}Mb/s (expected 1000)"
    fi
    echo "${status}|Link|${detail}"
}

check_link_errors() {
    local iface rx_errors rx_dropped rx_packets
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$iface" ]]; then
        echo "WARN|Link Errors|No active interface"
        return
    fi

    rx_errors=$(cat "/sys/class/net/${iface}/statistics/rx_errors" 2>/dev/null || echo 0)
    rx_dropped=$(cat "/sys/class/net/${iface}/statistics/rx_dropped" 2>/dev/null || echo 0)
    rx_packets=$(cat "/sys/class/net/${iface}/statistics/rx_packets" 2>/dev/null || echo 1)

    local total=$((rx_errors + rx_dropped))
    local detail="${rx_errors} err, ${rx_dropped} drop"

    # Rate-based thresholds: any errors are mildly suspect; errors above
    # 0.01% of RX packets indicate a real problem for wired LAN.
    # (0.01% = total * 10000 / rx_packets > 1)
    if [[ "$total" -eq 0 ]]; then
        echo "OK|Link Errors|0 err, 0 drop"
    elif [[ "$rx_packets" -gt 10000 && $((total * 10000 / rx_packets)) -gt 1 ]]; then
        echo "WARN|Link Errors|${detail} of ${rx_packets} rx"
    else
        echo "OK|Link Errors|${detail}"
    fi
}

check_nginx() {
    if systemctl is-active --quiet nginx 2>/dev/null; then
        if nc -z 127.0.0.1 1935 2>/dev/null; then
            echo "OK|nginx RTMP|Active, port 1935 open"
        else
            echo "WARN|nginx RTMP|Active but port 1935 not listening"
        fi
    else
        echo "FAIL|nginx RTMP|Service not running"
    fi
}

# The stream/key the player is configured to subscribe to. Informational —
# always OK — but critical for day-of-event triage: a publisher pushing to
# the wrong key looks identical to "no stream" without this line on screen.
check_player_config() {
    echo "OK|Player Stream|key=${STREAM_KEY}  (${STREAM_URL})"
}

check_rtmp_stream() {
    if ! nc -z 127.0.0.1 1935 2>/dev/null; then
        echo "WARN|RTMP Stream|nginx not ready"
        return
    fi
    if timeout 5 ffprobe -v quiet \
        -show_entries stream=codec_type \
        -of default=nw=1:nk=1 \
        "$STREAM_URL" 2>/dev/null | grep -q .; then
        echo "OK|RTMP Stream|Live (${STREAM_APP}/${STREAM_KEY})"
    else
        echo "WARN|RTMP Stream|No active stream on ${STREAM_APP}/${STREAM_KEY}"
    fi
}

# Publishers currently connected to nginx-rtmp, from the /stat XML. One line
# per publishing stream: OK when the key matches the player's, WARN on a
# mismatch (the 2026-05-03 splash-stuck failure mode, visible on screen).
# Emits multiple result lines when several publishers are connected.
check_publishers() {
    local parser="${SCRIPT_DIR}/parse_stat.py"
    if ! command -v curl >/dev/null 2>&1; then
        echo "WARN|Publishers|curl not installed"
        return
    fi
    if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$parser" ]]; then
        echo "WARN|Publishers|python3 or parse_stat.py missing"
        return
    fi
    local xml
    if ! xml=$(curl -fsS --max-time 3 "$STAT_URL" 2>/dev/null); then
        echo "WARN|Publishers|stat endpoint unreachable (${STAT_URL})"
        return
    fi
    printf '%s' "$xml" \
        | python3 "$parser" status --expected-key "$STREAM_KEY" 2>/dev/null \
        || echo "WARN|Publishers|stat XML parse failed"
}

check_disk() {
    local usage
    usage=$(df / --output=pcent | tail -1 | tr -d ' %')
    if [[ "$usage" -ge 90 ]]; then
        echo "FAIL|Disk|${usage}% used"
    elif [[ "$usage" -ge 75 ]]; then
        echo "WARN|Disk|${usage}% used"
    else
        echo "OK|Disk|${usage}% used"
    fi
}

check_temperature() {
    local temp_file="/sys/class/thermal/thermal_zone0/temp"
    if [[ -r "$temp_file" ]]; then
        local raw temp
        raw=$(cat "$temp_file")
        temp=$((raw / 1000))
        if [[ "$temp" -ge 80 ]]; then
            echo "FAIL|CPU Temp|${temp}C (throttling likely)"
        elif [[ "$temp" -ge 70 ]]; then
            echo "WARN|CPU Temp|${temp}C"
        else
            echo "OK|CPU Temp|${temp}C"
        fi
    else
        echo "WARN|CPU Temp|Sensor not available"
    fi
}

check_memory() {
    local avail_kb total_kb pct
    avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [[ -n "$avail_kb" && -n "$total_kb" && "$total_kb" -gt 0 ]]; then
        pct=$(( (total_kb - avail_kb) * 100 / total_kb ))
        local avail_mb=$(( avail_kb / 1024 ))
        if [[ "$pct" -ge 90 ]]; then
            echo "FAIL|Memory|${pct}% used (${avail_mb}MB free)"
        elif [[ "$pct" -ge 75 ]]; then
            echo "WARN|Memory|${pct}% used (${avail_mb}MB free)"
        else
            echo "OK|Memory|${pct}% used (${avail_mb}MB free)"
        fi
    else
        echo "WARN|Memory|Could not read /proc/meminfo"
    fi
}

check_uptime() {
    local up
    up=$(uptime -p 2>/dev/null || echo "unknown")
    echo "OK|Uptime|${up}"
}

check_time_sync() {
    if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
        echo "OK|Time Sync|NTP synchronized"
    else
        echo "WARN|Time Sync|NTP not synchronized"
    fi
}

check_watchdog() {
    if [[ -c /dev/watchdog ]]; then
        echo "OK|Watchdog|Device present"
    else
        echo "WARN|Watchdog|/dev/watchdog not found"
    fi
}

check_display_mode() {
    local expected="${HDMI_MODE:-}"
    local output="${HDMI_OUTPUT:-HDMI-A-1}"

    if [[ -z "$expected" ]]; then
        echo "OK|Display Mode|HDMI_MODE unset (EDID picks)"
        return
    fi
    if ! command -v wlr-randr >/dev/null 2>&1; then
        echo "WARN|Display Mode|wlr-randr not installed"
        return
    fi

    local wlr_out
    if ! wlr_out=$(wlr-randr 2>/dev/null); then
        echo "WARN|Display Mode|wlr-randr failed (no Wayland session?)"
        return
    fi

    # Find the "(current)" mode line under the expected output block.
    # wlr-randr indents mode rows; the output header is unindented.
    local active_line
    active_line=$(printf '%s\n' "$wlr_out" | awk -v out="$output" '
        $0 ~ "^" out " " { in_blk = 1; next }
        in_blk && /^\S/  { in_blk = 0 }
        in_blk && (/\(current\)/ || /, current\)/) { print; exit }
    ')
    if [[ -z "$active_line" ]]; then
        echo "WARN|Display Mode|no (current) mode found for $output"
        return
    fi

    # Parse "1920x1080 px, 30.000000 Hz (current)" → WxH + integer Hz.
    local actual_wh actual_hz_int
    actual_wh=$(awk '{print $1}' <<<"$active_line")
    actual_hz_int=$(awk '{
        for (i=1; i<=NF; i++)
            if ($i ~ /^[0-9.]+$/ && $(i+1) ~ /^Hz/) { printf("%.0f", $i); exit }
    }' <<<"$active_line")

    # Parse expected "WxH@RATE[Hz|D]" → WxH + integer Hz.
    local exp_wh exp_hz exp_hz_int
    exp_wh="${expected%@*}"
    exp_hz="${expected#*@}"
    exp_hz_int=$(awk -v h="$exp_hz" 'BEGIN{ printf("%.0f", h+0) }')

    if [[ "$actual_wh" == "$exp_wh" && "$actual_hz_int" == "$exp_hz_int" ]]; then
        echo "OK|Display Mode|${actual_wh}@${actual_hz_int}Hz"
    else
        echo "WARN|Display Mode|active ${actual_wh}@${actual_hz_int}Hz, expected ${exp_wh}@${exp_hz_int}Hz"
    fi
}

check_audio() {
    if command -v wpctl &>/dev/null; then
        if wpctl status 2>/dev/null | grep -qi 'sink'; then
            echo "OK|Audio|PipeWire sink available"
        else
            echo "WARN|Audio|No PipeWire sink found"
        fi
    elif command -v aplay &>/dev/null; then
        if aplay -l 2>/dev/null | grep -q 'card'; then
            echo "OK|Audio|ALSA device available"
        else
            echo "WARN|Audio|No ALSA device found"
        fi
    else
        echo "WARN|Audio|No audio tools found"
    fi
}

# ---------------------------------------------------------------------------
# Run all checks concurrently and collect results in display order
# ---------------------------------------------------------------------------

CHECKS=(
    check_hostname
    check_ip
    check_gateway
    check_link
    check_link_errors
    check_nginx
    check_player_config
    check_rtmp_stream
    check_publishers
    check_disk
    check_memory
    check_temperature
    check_uptime
    check_time_sync
    check_watchdog
    check_display_mode
    check_audio
)

# Checks are independent, so run them all in parallel: each writes to its own
# file in a scratch dir and results are collected in CHECKS order afterwards
# (display order stays deterministic). Serial worst case is dominated by the
# 5s ffprobe timeout plus 3s curl timeout plus assorted nc/systemctl calls;
# parallel, the wall time is just the slowest single check.
CHECK_TMP=$(mktemp -d)
trap 'rm -rf "$CHECK_TMP"' EXIT

for i in "${!CHECKS[@]}"; do
    "${CHECKS[i]}" > "${CHECK_TMP}/${i}" 2>/dev/null &
done
wait

results=()
overall="OK"

for i in "${!CHECKS[@]}"; do
    got_output=0
    # A check may emit several result lines (check_publishers: one per
    # publisher); collect each as its own row on the screen.
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        results+=("$line")
        got_output=1
        status="${line%%|*}"
        if [[ "$status" == "FAIL" ]]; then
            overall="FAIL"
        elif [[ "$status" == "WARN" && "$overall" != "FAIL" ]]; then
            overall="WARN"
        fi
    done < "${CHECK_TMP}/${i}"
    # A crashed check (set -e in its subshell) leaves an empty file — surface
    # that as a warning row instead of silently dropping the line.
    if (( ! got_output )); then
        label="${CHECKS[i]#check_}"
        results+=("WARN|${label//_/ }|check produced no output")
        [[ "$overall" == "FAIL" ]] || overall="WARN"
    fi
done

# ---------------------------------------------------------------------------
# Render PNG with ImageMagick
# ---------------------------------------------------------------------------

draw_args=()

# Heading
timestamp=$(date '+%Y-%m-%d %H:%M:%S')
case "$overall" in
    OK)   heading_color="$COLOR_OK"  ; heading_text="ALL SYSTEMS OK" ;;
    WARN) heading_color="$COLOR_WARN"; heading_text="WARNINGS DETECTED" ;;
    FAIL) heading_color="$COLOR_FAIL"; heading_text="ERRORS DETECTED" ;;
esac

draw_args+=(
    -fill "$heading_color" -pointsize "$HEADING_SIZE"
    -draw "text ${MARGIN_LEFT},${MARGIN_TOP} '${heading_text}'"
)

# Timestamp below heading
y=$(( MARGIN_TOP + LINE_HEIGHT ))
draw_args+=(
    -fill "$COLOR_TEXT" -pointsize 22
    -draw "text ${MARGIN_LEFT},${y} '${timestamp}'"
)

# Separator
y=$(( y + 15 ))
draw_args+=(
    -fill "#333333"
    -draw "rectangle ${MARGIN_LEFT},${y} $(( WIDTH - MARGIN_LEFT )),$(( y + 2 ))"
)

y=$(( y + LINE_HEIGHT ))

# Status lines
for result in "${results[@]}"; do
    IFS='|' read -r status label detail <<< "$result"

    # Strip single quotes: label/detail are embedded inside the single-quoted
    # ImageMagick draw primitive, and incoming-stream keys are chosen by the
    # publisher — a quote would break the draw command.
    label="${label//\'/}"
    detail="${detail//\'/}"

    case "$status" in
        OK)   dot_color="$COLOR_OK" ;;
        WARN) dot_color="$COLOR_WARN" ;;
        FAIL) dot_color="$COLOR_FAIL" ;;
        *)    dot_color="$COLOR_TEXT" ;;
    esac

    # Status dot
    local_y=$y
    dot_y=$(( local_y - 8 ))
    draw_args+=(
        -fill "$dot_color"
        -draw "circle ${MARGIN_LEFT},${dot_y} $(( MARGIN_LEFT + 8 )),${dot_y}"
    )

    # Label and detail
    label_x=$(( MARGIN_LEFT + 25 ))
    detail_x=$(( MARGIN_LEFT + 250 ))
    draw_args+=(
        -fill "$COLOR_TEXT" -pointsize "$FONT_SIZE"
        -draw "text ${label_x},${local_y} '${label}'"
        -fill "#aaaaaa" -pointsize 24
        -draw "text ${detail_x},${local_y} '${detail}'"
    )

    y=$(( y + LINE_HEIGHT ))
done

# Footer
footer_y=$(( HEIGHT - 40 ))
draw_args+=(
    -fill "#555555" -pointsize 18
    -draw "text ${MARGIN_LEFT},${footer_y} 'display-pi kiosk | HDMI diagnostic output'"
)

convert -size "${WIDTH}x${HEIGHT}" "xc:${COLOR_BG}" \
    -font "$FONT" \
    "${draw_args[@]}" \
    "$OUTPUT"

# Print summary to stdout for logging
echo "status=${overall} output=${OUTPUT}"
for result in "${results[@]}"; do
    IFS='|' read -r status label detail <<< "$result"
    printf "  [%-4s] %-15s %s\n" "$status" "$label" "$detail"
done
