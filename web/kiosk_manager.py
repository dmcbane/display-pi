#!/usr/bin/env python3
"""
kiosk_manager.py — Volunteer kiosk web manager.

Single-page UI for managing splash images and controlling the kiosk service.
Auth is a static ?token= query parameter stored in /etc/kiosk-web.conf
(loaded via EnvironmentFile= in kiosk-web.service).

Listens on 127.0.0.1:5000; nginx on port 80 proxies all traffic here.
"""

import io
import os
import re
import subprocess
from pathlib import Path

from flask import Flask, abort, jsonify, request, send_file, send_from_directory
from PIL import Image

app = Flask(__name__, static_folder=None)

TOKEN      = os.environ.get('TOKEN', '')
SPLASH_DIR = Path(os.environ.get('SPLASH_DIR', '/var/lib/kiosk-splash'))
KIOSK_USER = os.environ.get('KIOSK_USER', 'kiosk')
MAX_BYTES  = 10 * 1024 * 1024
REQ_SIZE   = (1920, 1080)
ALLOWED    = {'.png', '.jpg', '.jpeg'}
THUMB_SIZE = (320, 180)


@app.before_request
def auth():
    if not TOKEN:
        abort(500, description='TOKEN not set in /etc/kiosk-web.conf')
    if request.args.get('token') != TOKEN:
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
      --ok-bg:   #dcfce7; --ok-fg:  #14532d;
      --err-bg:  #fee2e2; --err-fg: #7f1d1d;
    }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: var(--bg); color: var(--text);
           padding: 1.25rem 1rem; line-height: 1.5; }
    .wrap { max-width: 660px; margin: 0 auto; }
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
    @media (max-width: 420px) {
      .img-card { flex-wrap: wrap; }
      .img-acts { width: 100%; justify-content: flex-end; }
    }
  </style>
</head>
<body>
<div class="wrap">
  <h1>&#128247; Kiosk Manager</h1>
  <div class="sub">Manage splash images and control the display.</div>
  <div id="flash"></div>

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
</div>

<script>
const TOKEN = '%%TOKEN%%';
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

loadImages();
</script>
</body>
</html>"""

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
