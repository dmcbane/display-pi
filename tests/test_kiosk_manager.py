"""Unit tests for kiosk_manager.py.

Run via: tests/run-tests.sh  (it auto-creates a venv on first run)
Or directly: tests/kiosk-web-venv/bin/pytest tests/test_kiosk_manager.py -v
"""

import io
import os
import sys

import pytest

# Set env vars before the module-level import so TOKEN/SPLASH_DIR/KIOSK_USER
# are initialised to test values when kiosk_manager is first loaded.
os.environ.setdefault('TOKEN', 'test-token-abc123')
os.environ.setdefault('SPLASH_DIR', '/tmp/test-unused-kiosk-splash')
os.environ.setdefault('KIOSK_USER', 'testuser')

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'web'))
import kiosk_manager  # noqa: E402

TEST_TOKEN = 'test-token-abc123'


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(kiosk_manager, 'TOKEN', TEST_TOKEN)
    monkeypatch.setattr(kiosk_manager, 'SPLASH_DIR', tmp_path)
    kiosk_manager.app.config['TESTING'] = True
    with kiosk_manager.app.test_client() as c:
        yield c


def _make_png(width, height):
    from PIL import Image as PILImage
    img = PILImage.new('RGB', (width, height), color=(255, 0, 0))
    buf = io.BytesIO()
    img.save(buf, 'PNG')
    buf.seek(0)
    return buf.read()


def _upload(client, stem):
    data = _make_png(1920, 1080)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), f'{stem}.png')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 201
    return r.get_json()['name']


# ── _strip_prefix ────────────────────────────────────────────────────────────

def test_strip_prefix_basic():
    assert kiosk_manager._strip_prefix('01-foo') == 'foo'


def test_strip_prefix_no_prefix():
    assert kiosk_manager._strip_prefix('foo') == 'foo'


def test_strip_prefix_idempotent():
    stripped = kiosk_manager._strip_prefix('02-bar')
    assert kiosk_manager._strip_prefix(stripped) == 'bar'


def test_strip_prefix_stops_at_first():
    # Only the outermost NN- prefix is removed; inner one stays.
    assert kiosk_manager._strip_prefix('02-02-x') == '02-x'


# ── auth ─────────────────────────────────────────────────────────────────────

def test_auth_missing_token(client):
    r = client.get('/')
    assert r.status_code == 403


def test_auth_wrong_token(client):
    r = client.get('/?token=notvalid')
    assert r.status_code == 403


def test_auth_correct_token(client):
    r = client.get(f'/?token={TEST_TOKEN}')
    assert r.status_code == 200


# ── upload validation ────────────────────────────────────────────────────────

def test_upload_no_file(client):
    r = client.post(f'/api/images?token={TEST_TOKEN}')
    assert r.status_code == 400


def test_upload_wrong_type(client):
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(b'hello world'), 'note.txt')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 400
    body = r.get_json()['error']
    assert 'PNG' in body or 'JPEG' in body


def test_upload_wrong_dimensions(client):
    data = _make_png(640, 480)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), 'small.png')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 400
    body = r.get_json()['error']
    assert '640' in body or '1920' in body


def test_upload_oversize(client, monkeypatch):
    monkeypatch.setattr(kiosk_manager, 'MAX_BYTES', 100)
    data = _make_png(1920, 1080)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), 'big.png')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 400
    assert 'large' in r.get_json()['error'].lower()


def test_upload_valid(client):
    data = _make_png(1920, 1080)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), 'splash.png')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 201
    assert r.get_json()['name'].endswith('.png')


def test_upload_sanitizes_filename(client):
    """HTML special chars in uploaded filenames are replaced with underscores."""
    data = _make_png(1920, 1080)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), '<script>xss</script>.png')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 201
    name = r.get_json()['name']
    assert '<' not in name
    assert '>' not in name
    assert '"' not in name


# ── reorder ──────────────────────────────────────────────────────────────────

def test_reorder_reversal(client):
    a = _upload(client, 'alpha')
    b = _upload(client, 'beta')
    r = client.post(
        f'/api/reorder?token={TEST_TOKEN}',
        json={'order': [b, a]},
        content_type='application/json',
    )
    assert r.status_code == 200
    imgs = client.get(f'/api/images?token={TEST_TOKEN}').get_json()
    assert 'beta' in imgs[0]['name']
    assert 'alpha' in imgs[1]['name']


def test_reorder_unknown_name_rejected(client):
    _upload(client, 'alpha')
    r = client.post(
        f'/api/reorder?token={TEST_TOKEN}',
        json={'order': ['ghost.png']},
        content_type='application/json',
    )
    assert r.status_code == 400


def test_reorder_partial_list_rejected(client):
    a = _upload(client, 'alpha')
    _upload(client, 'beta')
    r = client.post(
        f'/api/reorder?token={TEST_TOKEN}',
        json={'order': [a]},
        content_type='application/json',
    )
    assert r.status_code == 400


def test_reorder_empty_body_rejected(client):
    r = client.post(
        f'/api/reorder?token={TEST_TOKEN}',
        json={},
        content_type='application/json',
    )
    assert r.status_code == 400


# ── status board ─────────────────────────────────────────────────────────────

VALID_STATUSES = {'OK', 'WARN', 'FAIL'}


def test_status_requires_token(client):
    r = client.get('/api/status')
    assert r.status_code == 403


def test_status_shape(client):
    """/api/status returns overall + a non-empty list of well-formed checks."""
    r = client.get(f'/api/status?token={TEST_TOKEN}')
    assert r.status_code == 200
    body = r.get_json()
    assert body['overall'] in VALID_STATUSES
    assert isinstance(body['updated'], str) and body['updated']
    assert isinstance(body['checks'], list) and body['checks']
    for c in body['checks']:
        assert set(c) >= {'status', 'label', 'detail'}
        assert c['status'] in VALID_STATUSES
        assert isinstance(c['label'], str) and c['label']


def test_status_includes_core_checks(client):
    """The board carries the always-assessable checks ported from render-status.sh."""
    body = client.get(f'/api/status?token={TEST_TOKEN}').get_json()
    labels = {c['label'] for c in body['checks']}
    for expected in ('Hostname', 'Network', 'Disk', 'Memory', 'Uptime'):
        assert expected in labels, f'missing {expected} in {labels}'


def test_status_hostname_reports_actual_host(client):
    import socket
    body = client.get(f'/api/status?token={TEST_TOKEN}').get_json()
    host = next(c for c in body['checks'] if c['label'] == 'Hostname')
    assert host['status'] == 'OK'
    assert socket.gethostname() in host['detail']


# ── overall aggregation ──────────────────────────────────────────────────────

def test_overall_all_ok():
    checks = [{'status': 'OK'}, {'status': 'OK'}]
    assert kiosk_manager._overall(checks) == 'OK'


def test_overall_warn_wins_over_ok():
    checks = [{'status': 'OK'}, {'status': 'WARN'}, {'status': 'OK'}]
    assert kiosk_manager._overall(checks) == 'WARN'


def test_overall_fail_wins_over_warn():
    checks = [{'status': 'WARN'}, {'status': 'FAIL'}, {'status': 'OK'}]
    assert kiosk_manager._overall(checks) == 'FAIL'


def test_overall_empty_is_ok():
    assert kiosk_manager._overall([]) == 'OK'


# ── kiosk player health (from /tmp/kiosk-health.json) ─────────────────────────

def test_kiosk_health_reads_json(tmp_path, monkeypatch):
    hf = tmp_path / 'kiosk-health.json'
    hf.write_text('{"status":"OK","message":"ok (10.0.0.5, iface=eth0)",'
                  '"updated":"2026-07-03T10:00:00-05:00"}')
    monkeypatch.setattr(kiosk_manager, 'HEALTH_FILE', hf)
    check = kiosk_manager._check_kiosk_player()
    assert check['status'] == 'OK'
    assert 'iface=eth0' in check['detail']


def test_kiosk_health_missing_file_warns(tmp_path, monkeypatch):
    monkeypatch.setattr(kiosk_manager, 'HEALTH_FILE', tmp_path / 'nope.json')
    check = kiosk_manager._check_kiosk_player()
    assert check['status'] == 'WARN'


def test_kiosk_health_stale_file_warns(tmp_path, monkeypatch):
    """A health file older than the freshness window is flagged, not trusted."""
    import os
    import time
    hf = tmp_path / 'kiosk-health.json'
    hf.write_text('{"status":"OK","message":"ok","updated":"old"}')
    old = time.time() - 600
    os.utime(hf, (old, old))
    monkeypatch.setattr(kiosk_manager, 'HEALTH_FILE', hf)
    check = kiosk_manager._check_kiosk_player()
    assert check['status'] == 'WARN'
    assert 'stale' in check['detail'].lower()


# ── uptime humanizer ─────────────────────────────────────────────────────────

def test_humanize_uptime_minutes():
    assert kiosk_manager._humanize_uptime(90) == 'up 1 minute'


def test_humanize_uptime_hours_and_days():
    # 2 days, 3 hours, 4 minutes
    secs = 2 * 86400 + 3 * 3600 + 4 * 60
    out = kiosk_manager._humanize_uptime(secs)
    assert out == 'up 2 days, 3 hours, 4 minutes'
