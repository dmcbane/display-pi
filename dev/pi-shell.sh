#!/bin/bash
#
# pi-shell.sh — SSH into the Pi with optional journal tailing
#
# Usage:
#   pi-shell.sh              # interactive shell
#   pi-shell.sh logs         # tail kiosk + nginx logs
#   pi-shell.sh status       # show kiosk service status + diagnostics
#   pi-shell.sh diag         # run render-status.sh and print results
#   pi-shell.sh cmd "..."    # run a one-shot command

set -euo pipefail

HOST="${1:-${KIOSK_HOST:-displaypi}}"
ACTION="${1:-shell}"
KIOSK_USER="${KIOSK_USER:-kiosk}"

# If first arg looks like a hostname (contains no spaces, no known action),
# shift and use second arg as action
case "$ACTION" in
    logs|status|diag|cmd|shell)
        HOST="${KIOSK_HOST:-displaypi}"
        ;;
    *)
        HOST="$ACTION"
        ACTION="${2:-shell}"
        shift || true
        ;;
esac

case "$ACTION" in
    logs)
        echo "=== Tailing kiosk player log and nginx error log ==="
        ssh -t "${HOST}" \
            "sudo tail -f /tmp/player.log /var/log/nginx/error.log"
        ;;
    status)
        ssh "${HOST}" bash <<REMOTE
echo "=== Kiosk Service ==="
KIOSK_UID=\$(id -u ${KIOSK_USER})
sudo -u ${KIOSK_USER} XDG_RUNTIME_DIR="/run/user/\${KIOSK_UID}" \
    systemctl --user status kiosk.service --no-pager || true

echo ""
echo "=== nginx ==="
sudo systemctl status nginx --no-pager -l || true

echo ""
echo "=== RTMP Port ==="
sudo ss -tlnp | grep 1935 || echo "Port 1935 not listening!"

echo ""
echo "=== Player Log (last 20 lines) ==="
sudo tail -20 /tmp/player.log 2>/dev/null || echo "No player log"

echo ""
echo "=== System ==="
echo "Uptime: \$(uptime)"
echo "Temp: \$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f C", \$1/1000}' || echo 'N/A')"
echo "Disk: \$(df -h / --output=pcent | tail -1 | tr -d ' ')"
echo "Memory: \$(free -h | awk '/^Mem:/ {printf "%s/%s (%s free)", \$3, \$2, \$4}')"
REMOTE
        ;;
    diag)
        ssh "${HOST}" \
            "sudo -u ${KIOSK_USER} /home/${KIOSK_USER}/display-pi/diagnostics/render-status.sh /tmp/kiosk-status.png"
        ;;
    cmd)
        shift
        ssh "${HOST}" "$@"
        ;;
    shell|*)
        ssh -t "${HOST}"
        ;;
esac
