#!/usr/bin/env python3
"""
kiosk_manager.py — Volunteer kiosk web manager.

Single-page UI for managing splash images and controlling the kiosk service.
Auth is a ?token= query parameter. The token from /etc/kiosk-web.conf (loaded
via EnvironmentFile= in kiosk-web.service) is a one-time *seed*; the live token
is the app-owned file /var/lib/kiosk-web/token, which the manager can rotate
without any elevated privilege. See current_token()/rotate_token().

Listens on 127.0.0.1:5000; nginx proxies all traffic here (over TLS once
kiosk-web-tls-setup.sh has run).
"""

import io
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import time
from datetime import datetime, timezone
from html import escape
from pathlib import Path

from flask import (Flask, Response, abort, jsonify, request, send_file,
                   send_from_directory)
from PIL import Image

app = Flask(__name__, static_folder=None)

TOKEN      = os.environ.get('TOKEN', '')
SPLASH_DIR = Path(os.environ.get('SPLASH_DIR', '/var/lib/kiosk-splash'))
KIOSK_USER = os.environ.get('KIOSK_USER', 'kiosk')
MAX_BYTES  = 10 * 1024 * 1024
REQ_SIZE   = (1920, 1080)
ALLOWED    = {'.png', '.jpg', '.jpeg'}
THUMB_SIZE = (320, 180)

# The rotatable token store. The app runs as the locked kiosk-web user and
# cannot write root's /etc/kiosk-web.conf, so the live token lives in a file
# this user owns (0600). When absent (fresh install) we fall back to the seed
# TOKEN from the conf until the first rotation writes the file.
STATE_DIR  = Path(os.environ.get('KIOSK_WEB_STATE', '/var/lib/kiosk-web'))
TOKEN_FILE = Path(os.environ.get('TOKEN_FILE', str(STATE_DIR / 'token')))

# health-monitor.sh rewrites this every 20s; healthcheck.sh treats 2 min of
# silence as unhealthy, so we use the same window to flag a stale snapshot.
HEALTH_FILE      = Path(os.environ.get('HEALTH_FILE', '/tmp/kiosk-health.json'))
HEALTH_STALE_SEC = 120


def current_token():
    """The live token: the rotatable state file if present, else the seed."""
    try:
        t = TOKEN_FILE.read_text().strip()
        if t:
            return t
    except OSError:
        pass
    return TOKEN


def _write_token(tok):
    """Persist a new token atomically, 0600, owned by this (kiosk-web) user."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = TOKEN_FILE.with_name(TOKEN_FILE.name + '.tmp')
    tmp.write_text(tok + '\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, TOKEN_FILE)


def _external_base_url():
    """Canonical https base for shareable links.

    Prefer an explicitly configured PUBLIC_URL (the domain the Let's Encrypt
    cert is issued for) so a downloadable shortcut never embeds a spoofable or
    inconsistent Host header. Fall back to the request's own scheme+host when
    PUBLIC_URL is unset (pre-TLS installs, local testing).
    """
    base = os.environ.get('PUBLIC_URL', '').strip().rstrip('/')
    return base or request.host_url.rstrip('/')


def _volunteer_url(token):
    return f'{_external_base_url()}/?token={token}'


@app.before_request
def auth():
    tok = current_token()
    if not tok:
        abort(500, description='TOKEN not set in /etc/kiosk-web.conf')
    provided = request.args.get('token', '')
    if not secrets.compare_digest(provided, tok):
        return '<h2>Access denied</h2><p>Missing or invalid token.</p>', 403


@app.errorhandler(400)
@app.errorhandler(404)
@app.errorhandler(500)
def json_error(e):
    return jsonify(error=str(e.description)), e.code


def _images():
    return [
        {'name': p.name, 'size': p.stat().st_size, 'index': i}
        for i, p in enumerate(sorted(
            p for p in SPLASH_DIR.iterdir()
            if p.is_file() and p.suffix.lower() in ALLOWED
        ))
    ]


def _strip_prefix(stem):
    return re.sub(r'^\d{2,}-', '', stem)


@app.route('/')
def index():
    return INDEX_HTML.replace('%%TOKEN%%', request.args.get('token', ''))


@app.route('/api/images')
def list_images():
    return jsonify(_images())


@app.route('/api/images/<name>')
def get_image(name):
    name = Path(name).name
    path = SPLASH_DIR / name
    if not path.is_file():
        abort(404, description='Image not found')
    if request.args.get('thumb') == '1':
        img = Image.open(path)
        img.thumbnail(THUMB_SIZE, Image.LANCZOS)
        if img.mode not in ('RGB', 'L'):
            img = img.convert('RGB')
        buf = io.BytesIO()
        img.save(buf, 'JPEG', quality=75)
        buf.seek(0)
        return send_file(buf, mimetype='image/jpeg')
    return send_from_directory(SPLASH_DIR, name,
                               as_attachment=request.args.get('dl') == '1')


@app.route('/api/images/<name>', methods=['DELETE'])
def delete_image(name):
    name = Path(name).name
    path = SPLASH_DIR / name
    if not path.is_file():
        abort(404, description='Image not found')
    path.unlink()
    return jsonify({'ok': True})


@app.route('/api/images', methods=['POST'])
def upload_image():
    if 'file' not in request.files:
        abort(400, description='No file uploaded')
    f = request.files['file']
    suffix = Path(f.filename or '').suffix.lower()
    if suffix not in ALLOWED:
        abort(400, description='Only PNG and JPEG files are accepted')

    data = f.read()
    if len(data) > MAX_BYTES:
        abort(400, description=f'File too large (max {MAX_BYTES // 1024 // 1024} MB)')

    try:
        img = Image.open(io.BytesIO(data))
        img.verify()
        img = Image.open(io.BytesIO(data))
        w, h = img.size
        if (w, h) != REQ_SIZE:
            abort(400, description=f'Image must be {REQ_SIZE[0]}×{REQ_SIZE[1]} px '
                                   f'(uploaded image is {w}×{h})')
    except Exception as exc:
        if hasattr(exc, 'description'):
            raise
        abort(400, description=f'Invalid image file: {exc}')

    existing = _images()
    n = len(existing) + 1
    clean = re.sub(r'[^A-Za-z0-9._-]', '_', _strip_prefix(Path(f.filename).stem))
    dest_name = f'{n:02d}-{clean}{suffix}'
    dest = SPLASH_DIR / dest_name
    counter = 1
    while dest.exists():
        dest_name = f'{n:02d}-{clean}-{counter}{suffix}'
        dest = SPLASH_DIR / dest_name
        counter += 1

    dest.write_bytes(data)
    return jsonify({'ok': True, 'name': dest_name}), 201


@app.route('/api/reorder', methods=['POST'])
def reorder():
    body = request.get_json(silent=True) or {}
    ordered = [Path(n).name for n in body.get('order', [])]
    if not ordered:
        abort(400, description='Expected JSON: {"order": [...]}')

    existing = {img['name'] for img in _images()}
    if set(ordered) != existing:
        abort(400, description='Order list must contain exactly the current set of images')

    tmp_info = []
    try:
        for i, name in enumerate(ordered):
            src = SPLASH_DIR / name
            stem = _strip_prefix(src.stem)
            tmp = SPLASH_DIR / f'__reorder_{i:04d}{src.suffix.lower()}'
            src.rename(tmp)
            tmp_info.append((tmp, stem))

        for i, (tmp, stem) in enumerate(tmp_info):
            tmp.rename(SPLASH_DIR / f'{i + 1:02d}-{stem}{tmp.suffix}')
    except OSError as exc:
        abort(500, description=f'Reorder failed: {exc}')

    return jsonify({'ok': True})


@app.route('/api/restart', methods=['POST'])
def restart_kiosk():
    try:
        uid = subprocess.check_output(['id', '-u', KIOSK_USER], text=True).strip()
        xdg = f'/run/user/{uid}'
        subprocess.run(
            ['sudo', '-u', KIOSK_USER,
             f'XDG_RUNTIME_DIR={xdg}',
             f'DBUS_SESSION_BUS_ADDRESS=unix:path={xdg}/bus',
             'systemctl', '--user', 'restart', 'kiosk.service'],
            check=True, capture_output=True, text=True, timeout=15)
    except subprocess.CalledProcessError as exc:
        abort(500, description=f'Restart failed: {exc.stderr.strip()}')
    except subprocess.TimeoutExpired:
        abort(500, description='Restart timed out')
    return jsonify({'ok': True})


@app.route('/api/reboot', methods=['POST'])
def reboot_pi():
    subprocess.Popen(['sudo', 'reboot'])
    return jsonify({'ok': True})


# ── access token: view, rotate, and download shortcut files ──────────────────

def _webloc(url):
    """A macOS .webloc (an XML plist wrapping the URL)."""
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n\t<key>URL</key>\n'
            f'\t<string>{escape(url)}</string>\n</dict>\n</plist>\n')


def _urlfile(url):
    """A Windows/Linux .url internet shortcut."""
    return f'[InternetShortcut]\nURL={url}\n'


def _download(body, filename, mimetype):
    return Response(body, mimetype=mimetype, headers={
        'Content-Disposition': f'attachment; filename="{filename}"'})


@app.route('/api/token')
def token_info():
    tok = current_token()
    return jsonify({'token': tok, 'url': _volunteer_url(tok)})


@app.route('/api/token/rotate', methods=['POST'])
def rotate_token():
    new = secrets.token_urlsafe(32)
    try:
        _write_token(new)
    except OSError as exc:
        abort(500, description=f'Could not save new token: {exc}')
    return jsonify({'ok': True, 'token': new, 'url': _volunteer_url(new)})


@app.route('/api/token/webloc')
def token_webloc():
    body = _webloc(_volunteer_url(current_token()))
    return _download(body, 'volunteer-kiosk.webloc', 'application/octet-stream')


@app.route('/api/token/url')
def token_urlfile():
    body = _urlfile(_volunteer_url(current_token()))
    return _download(body, 'volunteer-kiosk.url', 'application/octet-stream')


# ── status board ─────────────────────────────────────────────────────────────
#
# A Python port of diagnostics/render-status.sh, the health board shown on HDMI
# at boot. The web manager runs as the locked `kiosk-web` user and is installed
# as a standalone file (it cannot read the repo under /home/kiosk), so the
# checks are re-implemented here rather than shelled out. Checks that need the
# Wayland/PipeWire *session* (Display Mode, Audio) are intentionally omitted —
# from this context they can't be assessed and would only ever WARN. Instead we
# surface the authoritative player/compositor liveness from the world-readable
# /tmp/kiosk-health.json that health-monitor.sh maintains.

RANK = {'OK': 0, 'WARN': 1, 'FAIL': 2}


def _overall(checks):
    """Worst status across all checks (FAIL > WARN > OK); OK when empty."""
    worst = 'OK'
    for c in checks:
        if RANK.get(c['status'], 0) > RANK[worst]:
            worst = c['status']
    return worst


def _read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def _run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (subprocess.SubprocessError, OSError):
        return None


def _default_iface():
    r = _run(['ip', '-4', 'route', 'show', 'default'])
    if r and r.returncode == 0:
        for line in r.stdout.splitlines():
            parts = line.split()
            if 'dev' in parts:
                return parts[parts.index('dev') + 1]
    return None


def _port_open(host, port):
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def _humanize_uptime(seconds):
    """Render seconds like `uptime -p`: 'up 2 days, 3 hours, 4 minutes'."""
    seconds = int(seconds)
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    parts = []
    for value, unit in ((days, 'day'), (hours, 'hour'), (minutes, 'minute')):
        if value:
            parts.append(f'{value} {unit}' + ('s' if value != 1 else ''))
    if not parts:
        parts.append('0 minutes')
    return 'up ' + ', '.join(parts)


def _check_hostname():
    return {'status': 'OK', 'label': 'Hostname', 'detail': socket.gethostname()}


def _check_ip():
    r = _run(['hostname', '-I'])
    ip = r.stdout.split()[0] if (r and r.returncode == 0 and r.stdout.split()) else ''
    if ip:
        return {'status': 'OK', 'label': 'Network', 'detail': ip}
    return {'status': 'FAIL', 'label': 'Network', 'detail': 'No IP address assigned'}


def _check_gateway():
    r = _run(['ip', 'route', 'show', 'default'])
    if r and r.returncode == 0 and r.stdout.strip():
        parts = r.stdout.split()
        gw = parts[parts.index('via') + 1] if 'via' in parts else '?'
        return {'status': 'OK', 'label': 'Gateway', 'detail': gw}
    return {'status': 'FAIL', 'label': 'Gateway', 'detail': 'No default route'}


def _check_link():
    iface = _default_iface()
    if not iface:
        return {'status': 'WARN', 'label': 'Link', 'detail': 'No active interface'}
    base = f'/sys/class/net/{iface}'
    if _read(f'{base}/carrier') != '1':
        return {'status': 'FAIL', 'label': 'Link', 'detail': f'{iface} carrier down'}
    speed = _read(f'{base}/speed') or '?'
    duplex = _read(f'{base}/duplex') or '?'
    if speed not in ('1000', '?'):
        return {'status': 'WARN', 'label': 'Link',
                'detail': f'{iface} @ {speed}Mb/s (expected 1000)'}
    return {'status': 'OK', 'label': 'Link', 'detail': f'{iface} @ {speed}Mb/s {duplex}'}


def _check_link_errors():
    iface = _default_iface()
    if not iface:
        return {'status': 'WARN', 'label': 'Link Errors', 'detail': 'No active interface'}
    stats = f'/sys/class/net/{iface}/statistics'
    rx_errors = int(_read(f'{stats}/rx_errors') or 0)
    rx_dropped = int(_read(f'{stats}/rx_dropped') or 0)
    rx_packets = int(_read(f'{stats}/rx_packets') or 1)
    total = rx_errors + rx_dropped
    detail = f'{rx_errors} err, {rx_dropped} drop'
    # Any errors are mildly suspect; above 0.01% of RX packets is a real problem.
    if total and rx_packets > 10000 and (total * 10000 // rx_packets) > 1:
        return {'status': 'WARN', 'label': 'Link Errors',
                'detail': f'{detail} of {rx_packets} rx'}
    return {'status': 'OK', 'label': 'Link Errors', 'detail': detail}


def _check_nginx():
    r = _run(['systemctl', 'is-active', '--quiet', 'nginx'])
    active = bool(r) and r.returncode == 0
    if not active:
        return {'status': 'FAIL', 'label': 'nginx RTMP', 'detail': 'Service not running'}
    if _port_open('127.0.0.1', 1935):
        return {'status': 'OK', 'label': 'nginx RTMP', 'detail': 'Active, port 1935 open'}
    return {'status': 'WARN', 'label': 'nginx RTMP',
            'detail': 'Active but port 1935 not listening'}


def _check_rtmp_stream():
    if not _port_open('127.0.0.1', 1935):
        return {'status': 'WARN', 'label': 'RTMP Stream', 'detail': 'nginx not ready'}
    r = _run(['ffprobe', '-v', 'quiet', '-show_entries', 'stream=codec_type',
              '-of', 'default=nw=1:nk=1', 'rtmp://127.0.0.1/live/restoration'],
             timeout=6)
    if r and r.returncode == 0 and r.stdout.strip():
        return {'status': 'OK', 'label': 'RTMP Stream', 'detail': 'Live'}
    return {'status': 'WARN', 'label': 'RTMP Stream', 'detail': 'No active stream'}


def _check_disk():
    try:
        usage = shutil.disk_usage('/')
        pct = round(usage.used * 100 / usage.total)
    except OSError:
        return {'status': 'WARN', 'label': 'Disk', 'detail': 'Could not stat /'}
    detail = f'{pct}% used'
    if pct >= 90:
        return {'status': 'FAIL', 'label': 'Disk', 'detail': detail}
    if pct >= 75:
        return {'status': 'WARN', 'label': 'Disk', 'detail': detail}
    return {'status': 'OK', 'label': 'Disk', 'detail': detail}


def _check_memory():
    info = {}
    for line in (_read('/proc/meminfo') or '').splitlines():
        key, _, rest = line.partition(':')
        info[key] = int(rest.split()[0]) if rest.split() else 0
    total = info.get('MemTotal', 0)
    avail = info.get('MemAvailable', 0)
    if not total:
        return {'status': 'WARN', 'label': 'Memory', 'detail': 'Could not read /proc/meminfo'}
    pct = (total - avail) * 100 // total
    detail = f'{pct}% used ({avail // 1024}MB free)'
    if pct >= 90:
        return {'status': 'FAIL', 'label': 'Memory', 'detail': detail}
    if pct >= 75:
        return {'status': 'WARN', 'label': 'Memory', 'detail': detail}
    return {'status': 'OK', 'label': 'Memory', 'detail': detail}


def _check_temperature():
    raw = _read('/sys/class/thermal/thermal_zone0/temp')
    if raw is None or not raw.lstrip('-').isdigit():
        return {'status': 'WARN', 'label': 'CPU Temp', 'detail': 'Sensor not available'}
    temp = int(raw) // 1000
    if temp >= 80:
        return {'status': 'FAIL', 'label': 'CPU Temp', 'detail': f'{temp}C (throttling likely)'}
    if temp >= 70:
        return {'status': 'WARN', 'label': 'CPU Temp', 'detail': f'{temp}C'}
    return {'status': 'OK', 'label': 'CPU Temp', 'detail': f'{temp}C'}


def _check_uptime():
    raw = _read('/proc/uptime')
    if not raw:
        return {'status': 'OK', 'label': 'Uptime', 'detail': 'unknown'}
    return {'status': 'OK', 'label': 'Uptime',
            'detail': _humanize_uptime(float(raw.split()[0]))}


def _check_time_sync():
    r = _run(['timedatectl', 'show'])
    if r and r.returncode == 0 and 'NTPSynchronized=yes' in r.stdout:
        return {'status': 'OK', 'label': 'Time Sync', 'detail': 'NTP synchronized'}
    return {'status': 'WARN', 'label': 'Time Sync', 'detail': 'NTP not synchronized'}


def _check_watchdog():
    if Path('/dev/watchdog').is_char_device():
        return {'status': 'OK', 'label': 'Watchdog', 'detail': 'Device present'}
    return {'status': 'WARN', 'label': 'Watchdog', 'detail': '/dev/watchdog not found'}


def _check_kiosk_player():
    """Report player/compositor liveness from health-monitor.sh's snapshot.

    This is the one check the web user can't compute itself — it depends on the
    kiosk user's session — so we trust the file health-monitor.sh writes, and
    flag it if it has gone stale (the monitor or player loop is stuck).
    """
    try:
        mtime = HEALTH_FILE.stat().st_mtime
        data = json.loads(HEALTH_FILE.read_text())
    except (OSError, ValueError):
        return {'status': 'WARN', 'label': 'Kiosk Player',
                'detail': 'No health snapshot yet'}
    age = time.time() - mtime
    message = data.get('message', '')
    if age > HEALTH_STALE_SEC:
        return {'status': 'WARN', 'label': 'Kiosk Player',
                'detail': f'Snapshot stale ({int(age)}s old): {message}'.rstrip(': ')}
    status = data.get('status', 'WARN')
    if status not in RANK:
        status = 'WARN'
    return {'status': status, 'label': 'Kiosk Player', 'detail': message or status}


STATUS_CHECKS = (
    _check_hostname,
    _check_ip,
    _check_gateway,
    _check_link,
    _check_link_errors,
    _check_nginx,
    _check_rtmp_stream,
    _check_kiosk_player,
    _check_disk,
    _check_memory,
    _check_temperature,
    _check_uptime,
    _check_time_sync,
    _check_watchdog,
)


def build_status():
    checks = []
    for fn in STATUS_CHECKS:
        try:
            checks.append(fn())
        except Exception as exc:  # a probe must never take the board down
            checks.append({'status': 'WARN',
                           'label': fn.__name__.replace('_check_', '').replace('_', ' ').title(),
                           'detail': f'check error: {exc}'})
    return {
        'overall': _overall(checks),
        'checks': checks,
        'updated': datetime.now(timezone.utc).isoformat(timespec='seconds'),
    }


@app.route('/api/status')
def status():
    return jsonify(build_status())


INDEX_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Kiosk Manager</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg:      #f0f2f5;
      --surface: #fff;
      --border:  #e5e7eb;
      --text:    #1f2937;
      --muted:   #6b7280;
      --primary: #2563eb;
      --danger:  #dc2626;
      --warn:    #d97706;
      --ok:      #16a34a;
      --ok-bg:   #dcfce7; --ok-fg:  #14532d;
      --err-bg:  #fee2e2; --err-fg: #7f1d1d;
    }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: var(--bg); color: var(--text);
           padding: 1.25rem 1rem; line-height: 1.5; }
    .wrap { max-width: 1040px; margin: 0 auto; }
    .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 1.25rem; align-items: start; }
    .col { min-width: 0; }
    @media (max-width: 760px) { .columns { grid-template-columns: 1fr; } }
    h1  { font-size: 1.35rem; font-weight: 700; margin-bottom: 0.2rem; }
    .sub { color: var(--muted); font-size: .85rem; margin-bottom: 1.4rem; }
    .card { background: var(--surface); border: 1px solid var(--border);
            border-radius: 10px; padding: 1.25rem; margin-bottom: 1.25rem; }
    .card-title { font-size: .95rem; font-weight: 600; margin-bottom: 1rem; }
    .btn { display: inline-flex; align-items: center; justify-content: center; gap: .35rem;
           padding: .5rem 1rem; border: none; border-radius: 6px; font-size: .875rem;
           font-weight: 500; cursor: pointer; transition: filter .15s;
           white-space: nowrap; text-decoration: none; }
    .btn:disabled { opacity: .45; cursor: not-allowed; }
    .btn:not(:disabled):hover { filter: brightness(.9); }
    .btn-primary { background: var(--primary); color: #fff; }
    .btn-danger  { background: var(--danger);  color: #fff; }
    .btn-warn    { background: var(--warn);    color: #fff; }
    .btn-ghost   { background: transparent; border: 1px solid var(--border); color: var(--muted); }
    .btn-ghost:not(:disabled):hover { color: var(--text); background: var(--bg); }
    .btn-sm { padding: .28rem .52rem; font-size: .78rem; }
    #flash { padding: .7rem 1rem; border-radius: 8px; margin-bottom: 1rem;
             font-size: .875rem; display: none; }
    #flash.ok  { background: var(--ok-bg);  color: var(--ok-fg); }
    #flash.err { background: var(--err-bg); color: var(--err-fg); }
    .upload-row { display: flex; align-items: center; gap: .75rem; flex-wrap: wrap; }
    #upload-hint { font-size: .8rem; color: var(--muted); }
    #image-list { margin-top: 1rem; display: flex; flex-direction: column; gap: .6rem; }
    .img-card { display: flex; align-items: center; gap: .7rem; padding: .6rem;
                background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
                cursor: grab; user-select: none; }
    .img-card.dragging  { opacity: .3; }
    .img-card.drag-over { border-color: var(--primary); box-shadow: 0 0 0 2px #2563eb44; }
    .order-col { display: flex; flex-direction: column; gap: 2px; flex-shrink: 0; }
    .img-thumb { width: 90px; height: 51px; object-fit: cover; border-radius: 4px;
                 background: var(--border); flex-shrink: 0; }
    .img-info  { flex: 1; min-width: 0; }
    .img-name  { font-size: .83rem; font-weight: 500; overflow: hidden;
                 text-overflow: ellipsis; white-space: nowrap; }
    .img-meta  { font-size: .73rem; color: var(--muted); margin-top: 1px; }
    .img-acts  { display: flex; gap: .35rem; flex-shrink: 0; }
    .empty { text-align: center; padding: 1.5rem; color: var(--muted); font-size: .875rem; }
    .ctrl-row  { display: flex; gap: .75rem; flex-wrap: wrap; }
    .ctrl-row .btn { flex: 1; min-width: 138px; padding: .7rem 1rem; }
    .ctrl-note { margin-top: .7rem; font-size: .78rem; color: var(--muted); }
    .link-row { display: flex; gap: .5rem; align-items: center; }
    .link-input { flex: 1; min-width: 0; padding: .5rem .6rem; border-radius: 6px;
                  border: 1px solid var(--border); background: var(--bg); color: var(--text);
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .76rem; }
    .card-head { display: flex; align-items: center; justify-content: space-between;
                 gap: .5rem; margin-bottom: 1rem; }
    .card-head .card-title { margin-bottom: 0; }
    .status-overall { display: inline-flex; align-items: center; gap: .4rem;
                      padding: .5rem .8rem; border-radius: 8px; font-weight: 600;
                      font-size: .85rem; margin-bottom: .9rem; }
    .status-overall.ok   { background: var(--ok-bg);  color: var(--ok-fg); }
    .status-overall.warn { background: #fef3c7; color: #78350f; }
    .status-overall.fail { background: var(--err-bg); color: var(--err-fg); }
    .status-grid { display: grid; grid-template-columns: 1fr; gap: 0; }
    .status-item { display: flex; align-items: baseline; gap: .6rem;
                   padding: .5rem .1rem; border-top: 1px solid var(--border); }
    .status-item:first-child { border-top: none; }
    .status-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0;
                  align-self: center; }
    .status-dot.ok   { background: var(--ok); }
    .status-dot.warn { background: var(--warn); }
    .status-dot.fail { background: var(--danger); }
    .status-label  { font-size: .84rem; font-weight: 500; flex-shrink: 0; width: 108px; }
    .status-detail { font-size: .8rem; color: var(--muted); word-break: break-word; }
    .status-foot { margin-top: .8rem; font-size: .74rem; color: var(--muted);
                   display: flex; align-items: center; justify-content: space-between; gap: .5rem; }
    .spin { animation: spin 1s linear infinite; display: inline-block; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .page-foot { text-align: center; margin-top: .25rem; font-size: .82rem; }
    .page-foot a { color: var(--muted); text-decoration: none; }
    .page-foot a:hover { color: var(--primary); text-decoration: underline; }
    @media (max-width: 420px) {
      .img-card { flex-wrap: wrap; }
      .img-acts { width: 100%; justify-content: flex-end; }
    }
  </style>
</head>
<body>
<div class="wrap">
  <h1>&#128247; Kiosk Manager</h1>
  <div class="sub">Manage splash images, watch system health, and control the display.</div>
  <div id="flash"></div>

  <div class="columns">
    <div class="col">
      <div class="card">
        <div class="card-title">Splash Images</div>
        <div class="upload-row">
          <input type="file" id="file-input" accept=".png,.jpg,.jpeg" style="display:none">
          <button class="btn btn-primary" id="upload-btn"
                  onclick="document.getElementById('file-input').click()">&#43; Upload Image</button>
          <span id="upload-hint">PNG or JPEG &middot; 1920&times;1080 &middot; max 10 MB</span>
        </div>
        <div id="image-list"></div>
      </div>

      <div class="card">
        <div class="card-title">Kiosk Controls</div>
        <div class="ctrl-row">
          <button class="btn btn-warn"   id="restart-btn">&#x21BB; Restart Service</button>
          <button class="btn btn-danger" id="reboot-btn">&#x23FB; Reboot Pi</button>
        </div>
        <p class="ctrl-note">Restart applies image changes immediately. Reboot takes ~30 s.</p>
      </div>

      <div class="card">
        <div class="card-title">Access Link</div>
        <div class="link-row">
          <input class="link-input" id="link-input" type="text" readonly value="loading…">
          <button class="btn btn-ghost btn-sm" id="copy-btn" title="Copy link">Copy</button>
        </div>
        <div class="ctrl-row" style="margin-top:.7rem">
          <a class="btn btn-ghost" id="dl-webloc" download="volunteer-kiosk.webloc">&#11015; .webloc (Mac)</a>
          <a class="btn btn-ghost" id="dl-url" download="volunteer-kiosk.url">&#11015; .url (Win/Linux)</a>
        </div>
        <div class="ctrl-row" style="margin-top:.7rem">
          <button class="btn btn-danger" id="rotate-btn">&#x21BB; Rotate Token</button>
        </div>
        <p class="ctrl-note">Rotating generates a new link and <strong>immediately invalidates
          every existing link</strong>. Re-share the new link or download a fresh shortcut.</p>
      </div>
    </div>

    <div class="col">
      <div class="card">
        <div class="card-head">
          <div class="card-title">System Status</div>
          <button class="btn btn-ghost btn-sm" id="status-refresh" title="Refresh now">&#x21BB;</button>
        </div>
        <div id="status-overall" class="status-overall">Loading…</div>
        <div id="status-grid" class="status-grid"></div>
        <div class="status-foot">
          <span id="status-updated">—</span>
          <span>auto-refreshes every 15 s</span>
        </div>
      </div>
    </div>
  </div>

  <div class="page-foot">
    <a href="https://dmcbane.github.io/display-pi/" target="_blank" rel="noopener">&#128214; Documentation</a>
  </div>
</div>

<script>
let TOKEN = '%%TOKEN%%';
const qs = (extra) => { const p = new URLSearchParams({token: TOKEN, ...extra}); return '?' + p; };

function apiFetch(path, opts, extra) {
  return fetch(path + qs(extra || {}), opts || {}).then(r => {
    if (!r.ok) return r.text().then(t => {
      let msg = t; try { msg = JSON.parse(t).error || t; } catch(_) {}
      return Promise.reject(msg || 'HTTP ' + r.status);
    });
    return r.json();
  });
}

let images = [];

function flash(msg, isOk) {
  const el = document.getElementById('flash');
  el.textContent = msg;
  el.className = isOk === false ? 'err' : 'ok';
  el.style.display = 'block';
  clearTimeout(el._t);
  el._t = setTimeout(() => { el.style.display = 'none'; }, 5000);
}

function fmtSize(b) {
  return b < 1048576 ? Math.round(b / 1024) + ' KB' : (b / 1048576).toFixed(1) + ' MB';
}

function renderImages() {
  const list = document.getElementById('image-list');
  if (!images.length) {
    list.innerHTML = '<div class="empty">No images yet — upload one above.</div>';
    return;
  }
  list.innerHTML = '';
  images.forEach((img, i) => {
    const card = document.createElement('div');
    card.className = 'img-card';
    card.draggable = true;
    card.innerHTML =
      '<div class="order-col">' +
        '<button class="btn btn-ghost btn-sm" data-dir="-1" title="Move up"'   + (i === 0 ? ' disabled' : '') + '>&#9650;</button>' +
        '<button class="btn btn-ghost btn-sm" data-dir="1"  title="Move down"' + (i === images.length - 1 ? ' disabled' : '') + '>&#9660;</button>' +
      '</div>' +
      '<img class="img-thumb" src="/api/images/' + encodeURIComponent(img.name) + qs({thumb:'1'}) + '" alt="" loading="lazy">' +
      '<div class="img-info">' +
        '<div class="img-name" title="' + img.name + '">' + img.name + '</div>' +
        '<div class="img-meta">' + fmtSize(img.size) + '</div>' +
      '</div>' +
      '<div class="img-acts">' +
        '<a class="btn btn-ghost btn-sm" href="/api/images/' + encodeURIComponent(img.name) + qs({dl:'1'}) + '" download="' + img.name + '" title="Download">&#11015;</a>' +
        '<button class="btn btn-danger btn-sm" data-name="' + img.name + '" title="Delete">&#10005;</button>' +
      '</div>';

    card.querySelectorAll('[data-dir]').forEach(btn => {
      btn.addEventListener('click', e => {
        e.stopPropagation();
        const ni = i + parseInt(btn.dataset.dir);
        if (ni < 0 || ni >= images.length) return;
        [images[i], images[ni]] = [images[ni], images[i]];
        saveOrder();
      });
    });

    card.querySelector('[data-name]').addEventListener('click', e => {
      e.stopPropagation();
      const name = e.currentTarget.dataset.name;
      if (!confirm('Delete "' + name + '"?')) return;
      apiFetch('/api/images/' + encodeURIComponent(name), {method: 'DELETE'})
        .then(() => { flash('Deleted ' + name); loadImages(); })
        .catch(err => flash('Delete failed: ' + err, false));
    });

    card.addEventListener('dragstart', ev => {
      ev.dataTransfer.effectAllowed = 'move';
      ev.dataTransfer.setData('text/plain', String(i));
      setTimeout(() => card.classList.add('dragging'), 0);
    });
    card.addEventListener('dragend',  () => card.classList.remove('dragging'));
    card.addEventListener('dragover', ev => { ev.preventDefault(); card.classList.add('drag-over'); });
    card.addEventListener('dragleave', () => card.classList.remove('drag-over'));
    card.addEventListener('drop', ev => {
      ev.preventDefault();
      card.classList.remove('drag-over');
      const from = parseInt(ev.dataTransfer.getData('text/plain'));
      if (from === i) return;
      const moved = images.splice(from, 1)[0];
      images.splice(i, 0, moved);
      saveOrder();
    });

    list.appendChild(card);
  });
}

function loadImages() {
  apiFetch('/api/images')
    .then(data => { images = data; renderImages(); })
    .catch(err => flash('Failed to load images: ' + err, false));
}

function saveOrder() {
  renderImages();
  apiFetch('/api/reorder', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({order: images.map(img => img.name)})
  })
    .then(() => { flash('Order saved'); loadImages(); })
    .catch(err => { flash('Reorder failed: ' + err, false); loadImages(); });
}

document.getElementById('file-input').addEventListener('change', function() {
  const file = this.files[0];
  if (!file) return;
  const hint = document.getElementById('upload-hint');
  const btn  = document.getElementById('upload-btn');
  hint.textContent = 'Uploading ' + file.name + '…';
  btn.disabled = true;
  const fd = new FormData();
  fd.append('file', file);
  fetch('/api/images' + qs(), {method: 'POST', body: fd})
    .then(r => {
      if (!r.ok) return r.text().then(t => {
        let msg = t; try { msg = JSON.parse(t).error || t; } catch(_) {}
        return Promise.reject(msg);
      });
      return r.json();
    })
    .then(data => { flash('Uploaded ' + data.name); loadImages(); })
    .catch(err => flash('Upload failed: ' + err, false))
    .finally(() => {
      hint.textContent = 'PNG or JPEG · 1920×1080 · max 10 MB';
      btn.disabled = false;
      this.value = '';
    });
});

document.getElementById('restart-btn').addEventListener('click', () => {
  if (!confirm('Restart the kiosk service?\nThe display will briefly show the splash screen.')) return;
  apiFetch('/api/restart', {method: 'POST'})
    .then(() => flash('Kiosk service restarted'))
    .catch(err => flash('Restart failed: ' + err, false));
});

document.getElementById('reboot-btn').addEventListener('click', () => {
  if (!confirm('Reboot the Pi?\nThe display and this page will be unreachable for ~30 seconds.')) return;
  apiFetch('/api/reboot', {method: 'POST'})
    .then(() => flash('Pi is rebooting — page unavailable for ~30 seconds'))
    .catch(err => flash('Reboot failed: ' + err, false));
});

// ── Access link & token rotation ────────────────────────────────────────────
function refreshDownloadLinks() {
  document.getElementById('dl-webloc').href = '/api/token/webloc' + qs();
  document.getElementById('dl-url').href    = '/api/token/url' + qs();
}

function refreshLink() {
  apiFetch('/api/token')
    .then(data => { document.getElementById('link-input').value = data.url; })
    .catch(err => flash('Could not load link: ' + err, false));
  refreshDownloadLinks();
}

document.getElementById('copy-btn').addEventListener('click', () => {
  const input = document.getElementById('link-input');
  const copy = navigator.clipboard
    ? navigator.clipboard.writeText(input.value)
    : (input.select(), document.execCommand('copy'), Promise.resolve());
  Promise.resolve(copy)
    .then(() => flash('Link copied to clipboard'))
    .catch(() => flash('Copy failed — select the link manually', false));
});

document.getElementById('rotate-btn').addEventListener('click', () => {
  if (!confirm('Rotate the access token?\n\nEvery existing link (including any shared '
      + 'shortcut files) stops working immediately. This page will switch to the new link.')) return;
  apiFetch('/api/token/rotate', {method: 'POST'})
    .then(data => {
      TOKEN = data.token;                                  // re-key this open page
      history.replaceState({}, '', '/?token=' + encodeURIComponent(TOKEN));
      document.getElementById('link-input').value = data.url;
      refreshDownloadLinks();
      flash('Token rotated — old links are now invalid. Re-share the new link.');
    })
    .catch(err => flash('Rotate failed: ' + err, false));
});

// ── System status board ─────────────────────────────────────────────────────
const STATUS_TEXT = {OK: 'All systems OK', WARN: 'Warnings detected', FAIL: 'Errors detected'};
let statusTimer = null;

function esc(s) {
  const d = document.createElement('div');
  d.textContent = s == null ? '' : String(s);
  return d.innerHTML;
}

function renderStatus(data) {
  const overall = document.getElementById('status-overall');
  const cls = (data.overall || 'WARN').toLowerCase();
  overall.className = 'status-overall ' + cls;
  overall.textContent = STATUS_TEXT[data.overall] || data.overall || 'Unknown';

  const grid = document.getElementById('status-grid');
  grid.innerHTML = (data.checks || []).map(c => {
    const k = (c.status || 'WARN').toLowerCase();
    return '<div class="status-item">' +
             '<span class="status-dot ' + k + '"></span>' +
             '<span class="status-label">' + esc(c.label) + '</span>' +
             '<span class="status-detail">' + esc(c.detail) + '</span>' +
           '</div>';
  }).join('');

  const updated = document.getElementById('status-updated');
  const d = new Date(data.updated);
  updated.textContent = isNaN(d) ? 'updated just now'
    : 'updated ' + d.toLocaleTimeString();
}

function loadStatus() {
  const btn = document.getElementById('status-refresh');
  btn.classList.add('spin');
  apiFetch('/api/status')
    .then(renderStatus)
    .catch(err => {
      const overall = document.getElementById('status-overall');
      overall.className = 'status-overall fail';
      overall.textContent = 'Status unavailable: ' + err;
    })
    .finally(() => btn.classList.remove('spin'));
}

document.getElementById('status-refresh').addEventListener('click', loadStatus);

function scheduleStatus() {
  clearInterval(statusTimer);
  statusTimer = setInterval(loadStatus, 15000);
}

loadImages();
refreshLink();
loadStatus();
scheduleStatus();
</script>
</body>
</html>"""

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
