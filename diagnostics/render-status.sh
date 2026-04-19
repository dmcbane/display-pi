#!/bin/bash
#
# render-status.sh — Generate a diagnostic status PNG for kiosk display
#
# Checks system health and renders results as a fullscreen PNG that mpv
# can display. Each check gets a colored indicator visible from across
# the room: green = OK, yellow = warning, red = critical.
#
# Usage: render-status.sh [output.png]
# Default output: /tmp/kiosk-status.png

set -euo pipefail

OUTPUT="${1:-/tmp/kiosk-status.png}"
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

check_rtmp_stream() {
    if ! nc -z 127.0.0.1 1935 2>/dev/null; then
        echo "WARN|RTMP Stream|nginx not ready"
        return
    fi
    if timeout 5 ffprobe -v quiet \
        -show_entries stream=codec_type \
        -of default=nw=1:nk=1 \
        "rtmp://127.0.0.1/live/church242" 2>/dev/null | grep -q .; then
        echo "OK|RTMP Stream|Live"
    else
        echo "WARN|RTMP Stream|No active stream"
    fi
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
# Run all checks and collect results
# ---------------------------------------------------------------------------

CHECKS=(
    check_hostname
    check_ip
    check_gateway
    check_nginx
    check_rtmp_stream
    check_disk
    check_memory
    check_temperature
    check_uptime
    check_time_sync
    check_watchdog
    check_audio
)

results=()
overall="OK"

for check_fn in "${CHECKS[@]}"; do
    result=$($check_fn)
    results+=("$result")
    status="${result%%|*}"
    if [[ "$status" == "FAIL" ]]; then
        overall="FAIL"
    elif [[ "$status" == "WARN" && "$overall" != "FAIL" ]]; then
        overall="WARN"
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
