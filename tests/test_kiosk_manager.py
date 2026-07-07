"""Unit tests for kiosk_manager.py.

Run via: tests/run-tests.sh  (it auto-creates a venv on first run)
Or directly: tests/kiosk-web-venv/bin/pytest tests/test_kiosk_manager.py -v
"""

import io
import json
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
    # Point the rotatable token store at a path that does not exist, so
    # current_token() falls back to the seed TOKEN for the auth tests.
    monkeypatch.setattr(kiosk_manager, 'TOKEN_FILE', tmp_path / 'no-token-file')
    monkeypatch.setattr(kiosk_manager, 'SPLASH_DIR', tmp_path)
    kiosk_manager.app.config['TESTING'] = True
    with kiosk_manager.app.test_client() as c:
        yield c


def _make_image(width, height, fmt='PNG'):
    from PIL import Image as PILImage
    img = PILImage.new('RGB', (width, height), color=(255, 0, 0))
    buf = io.BytesIO()
    img.save(buf, fmt)
    buf.seek(0)
    return buf.read()


def _make_png(width, height):
    return _make_image(width, height, 'PNG')


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
    # A valid ?token= renders the page and mints the hardened cookie; the page's
    # own JS then scrubs the token from the address bar.
    r = client.get(f'/?token={TEST_TOKEN}')
    assert r.status_code == 200


def test_index_has_documentation_link(client):
    """The manager links out to the published documentation site."""
    body = client.get(f'/?token={TEST_TOKEN}').get_data(as_text=True)
    assert 'https://dmcbane.github.io/display-pi/' in body


def test_index_token_echo_is_js_escaped(client):
    """The reflected ?token= must be injected inertly: json.dumps stops JS
    quote-breakout, and < > & escaping stops </script> block-breakout. auth()
    accepts the request on a valid cookie regardless of the query token, so the
    reflection is attacker-influenced on a live session."""
    # Authenticate first: the cookie carries the session, so the later request's
    # query token is attacker-influenced yet still reflected into the page.
    client.get(f'/?token={TEST_TOKEN}')
    # A payload trying to break out of both the JS string and the <script> block.
    payload = "</script><script>alert(1)</script>"
    html = client.get(f'/?token={payload}').get_data(as_text=True)
    # The injected sequence must never appear raw (it would close the block).
    assert '</script><script>alert(1)' not in html
    # It survives only as unicode-escaped, inert text inside the JS string.
    assert '\\u003c/script\\u003e' in html
# ── cookie hardening ─────────────────────────────────────────────────────────

def _set_cookie_header(response):
    """The raw Set-Cookie header for our auth cookie, or '' if none was set."""
    for h in response.headers.getlist('Set-Cookie'):
        if h.startswith(kiosk_manager.COOKIE_NAME + '='):
            return h
    return ''


def test_query_auth_mints_hardened_cookie(client):
    """A URL-token hit hands back a HttpOnly/SameSite=Strict session cookie."""
    r = client.get(f'/?token={TEST_TOKEN}')
    assert r.status_code == 200
    setc = _set_cookie_header(r)
    assert f'{kiosk_manager.COOKIE_NAME}={TEST_TOKEN}' in setc
    assert 'HttpOnly' in setc
    assert 'SameSite=Strict' in setc
    assert 'Path=/' in setc


def test_cookie_secure_flag_tracks_forwarded_proto(client):
    """Secure is set behind TLS (X-Forwarded-Proto: https) and omitted on plain HTTP."""
    over_http = _set_cookie_header(client.get(f'/?token={TEST_TOKEN}'))
    assert 'Secure' not in over_http

    over_https = _set_cookie_header(
        client.get(f'/?token={TEST_TOKEN}',
                   headers={'X-Forwarded-Proto': 'https'}))
    assert 'Secure' in over_https


def test_cookie_is_persistent(client):
    """The auth cookie carries a Max-Age so a bookmarked clean URL keeps working
    across browser restarts — the volunteer-friendly choice."""
    setc = _set_cookie_header(client.get(f'/?token={TEST_TOKEN}'))
    assert f'Max-Age={kiosk_manager.COOKIE_MAX_AGE}' in setc
    assert kiosk_manager.COOKIE_MAX_AGE >= 30 * 24 * 3600


def test_cookie_alone_authenticates(client):
    """After the cookie exists, a request with no ?token= is accepted."""
    client.set_cookie(kiosk_manager.COOKIE_NAME, TEST_TOKEN)
    r = client.get('/api/status')
    assert r.status_code == 200


def test_wrong_cookie_rejected(client):
    client.set_cookie(kiosk_manager.COOKIE_NAME, 'forged-value')
    r = client.get('/api/status')
    assert r.status_code == 403


def test_no_cookie_minted_on_denied_request(client):
    """A rejected request must never hand out an auth cookie."""
    r = client.get('/?token=wrong')
    assert r.status_code == 403
    assert _set_cookie_header(r) == ''


def test_index_scrubs_token_from_address_bar(client):
    """The page keeps the token in a JS var but strips it from the URL on load,
    and rotation must not re-plant it in the address bar."""
    html = client.get(f'/?token={TEST_TOKEN}').get_data(as_text=True)
    # Defined and invoked (>= one definition + one call site).
    assert html.count('stripTokenFromUrl') >= 2
    # The old behaviour — re-writing the token back into the URL — is gone.
    assert "'/?token=' + encodeURIComponent" not in html


def test_rotate_refreshes_cookie_to_new_token(client, tmp_path, monkeypatch):
    """Rotating via URL token re-keys the cookie to the new token, so the old
    cookie stops working and the browser is handed the new one."""
    tf = tmp_path / 'token'
    monkeypatch.setattr(kiosk_manager, 'STATE_DIR', tmp_path)
    monkeypatch.setattr(kiosk_manager, 'TOKEN_FILE', tf)
    r = client.post(f'/api/token/rotate?token={TEST_TOKEN}')
    assert r.status_code == 200
    new = r.get_json()['token']
    setc = _set_cookie_header(r)
    assert f'{kiosk_manager.COOKIE_NAME}={new}' in setc
    # The stale cookie no longer authenticates.
    client.set_cookie(kiosk_manager.COOKIE_NAME, TEST_TOKEN)
    assert client.get('/api/status').status_code == 403


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


def test_max_content_length_configured(client):
    """Flask MAX_CONTENT_LENGTH is set so an oversized body is rejected before
    the whole thing is buffered into RAM — defense-in-depth for the loopback
    path that bypasses nginx's client_max_body_size."""
    assert kiosk_manager.app.config['MAX_CONTENT_LENGTH'] == kiosk_manager.MAX_BYTES


def test_upload_body_over_hard_limit_rejected(client):
    """A body past MAX_CONTENT_LENGTH gets a 413 from Flask itself."""
    big = b'x' * (kiosk_manager.MAX_BYTES + 1)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(big), 'huge.png')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 413


def test_upload_valid(client):
    data = _make_png(1920, 1080)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), 'splash.png')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 201
    assert r.get_json()['name'].endswith('.png')


@pytest.mark.parametrize('fmt,ext', [
    ('JPEG', '.jpg'),
    ('GIF', '.gif'),
    ('WEBP', '.webp'),
])
def test_upload_accepts_all_formats(client, fmt, ext):
    """JPEG, GIF, and WebP are accepted alongside PNG (covered elsewhere)."""
    data = _make_image(1920, 1080, fmt)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), f'splash{ext}')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 201
    assert r.get_json()['name'].endswith(ext)


@pytest.mark.parametrize('fmt,ext', [
    ('GIF', '.gif'),
    ('WEBP', '.webp'),
])
def test_thumbnail_of_new_formats(client, fmt, ext):
    """Thumbnails render for GIF (palette mode) and WebP without erroring."""
    data = _make_image(1920, 1080, fmt)
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), f'slide{ext}')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 201
    name = r.get_json()['name']
    t = client.get(f'/api/images/{name}?thumb=1&token={TEST_TOKEN}')
    assert t.status_code == 200
    assert t.mimetype == 'image/jpeg'


def test_new_formats_appear_in_listing(client):
    """_images() includes .gif and .webp files so they join the rotation UI."""
    data = _make_image(1920, 1080, 'WEBP')
    r = client.post(
        f'/api/images?token={TEST_TOKEN}',
        data={'file': (io.BytesIO(data), 'announce.webp')},
        content_type='multipart/form-data',
    )
    assert r.status_code == 201
    names = [img['name'] for img in
             client.get(f'/api/images?token={TEST_TOKEN}').get_json()]
    assert r.get_json()['name'] in names


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


# ── stream config (single source: /etc/default/kiosk) ───────────────────────

STAT_XML_MATCH = b"""<?xml version="1.0"?>
<rtmp><server><application><name>live</name><live>
<stream><name>church242</name><bw_in>4200000</bw_in>
<client><address>192.168.1.50</address><publishing/></client>
</stream><nclients>1</nclients></live></application></server></rtmp>"""

STAT_XML_MISMATCH = STAT_XML_MATCH.replace(b'church242', b'wrongkey')

STAT_XML_IDLE = b"""<?xml version="1.0"?>
<rtmp><server><application><name>live</name><live>
<nclients>0</nclients></live></application></server></rtmp>"""


def test_stream_url_default_without_env_file(tmp_path, monkeypatch):
    monkeypatch.setattr(kiosk_manager, 'KIOSK_ENV_FILE', tmp_path / 'absent')
    monkeypatch.delenv('STREAM_URL', raising=False)
    assert kiosk_manager._stream_url() == 'rtmp://127.0.0.1/live/restoration'


def test_stream_url_read_from_env_file(tmp_path, monkeypatch):
    env = tmp_path / 'kiosk'
    env.write_text('SPLASH_DIR=/var/lib/kiosk-splash\n'
                   'STREAM_URL=rtmp://127.0.0.1/live/church242\n')
    monkeypatch.setattr(kiosk_manager, 'KIOSK_ENV_FILE', env)
    monkeypatch.delenv('STREAM_URL', raising=False)
    assert kiosk_manager._stream_url() == 'rtmp://127.0.0.1/live/church242'


def test_stream_url_env_var_wins_over_file(tmp_path, monkeypatch):
    env = tmp_path / 'kiosk'
    env.write_text('STREAM_URL=rtmp://127.0.0.1/live/fromfile\n')
    monkeypatch.setattr(kiosk_manager, 'KIOSK_ENV_FILE', env)
    monkeypatch.setenv('STREAM_URL', 'rtmp://127.0.0.1/live/fromenv')
    assert kiosk_manager._stream_url() == 'rtmp://127.0.0.1/live/fromenv'


def test_stream_key_derived_from_url(tmp_path, monkeypatch):
    env = tmp_path / 'kiosk'
    env.write_text('STREAM_URL=rtmp://127.0.0.1/live/church242\n')
    monkeypatch.setattr(kiosk_manager, 'KIOSK_ENV_FILE', env)
    monkeypatch.delenv('STREAM_URL', raising=False)
    assert kiosk_manager._stream_key() == 'church242'


def test_check_player_stream_shows_key_and_url(tmp_path, monkeypatch):
    env = tmp_path / 'kiosk'
    env.write_text('STREAM_URL=rtmp://127.0.0.1/live/church242\n')
    monkeypatch.setattr(kiosk_manager, 'KIOSK_ENV_FILE', env)
    monkeypatch.delenv('STREAM_URL', raising=False)
    row = kiosk_manager._check_player_stream()
    assert row['status'] == 'OK'
    assert row['label'] == 'Player Stream'
    assert 'church242' in row['detail']
    assert 'rtmp://127.0.0.1/live/church242' in row['detail']


def test_check_rtmp_stream_probes_configured_url(tmp_path, monkeypatch):
    env = tmp_path / 'kiosk'
    env.write_text('STREAM_URL=rtmp://127.0.0.1/live/church242\n')
    monkeypatch.setattr(kiosk_manager, 'KIOSK_ENV_FILE', env)
    monkeypatch.delenv('STREAM_URL', raising=False)
    monkeypatch.setattr(kiosk_manager, '_port_open', lambda *a, **k: True)
    seen = {}

    def fake_run(cmd, timeout=5):
        seen['cmd'] = cmd
        return None

    monkeypatch.setattr(kiosk_manager, '_run', fake_run)
    kiosk_manager._check_rtmp_stream()
    assert 'rtmp://127.0.0.1/live/church242' in seen['cmd']


def test_check_publishers_key_match(monkeypatch):
    monkeypatch.setattr(kiosk_manager, '_fetch_stat', lambda: STAT_XML_MATCH)
    monkeypatch.setattr(kiosk_manager, '_stream_key', lambda: 'church242')
    rows = kiosk_manager._check_publishers()
    assert len(rows) == 1
    assert rows[0]['status'] == 'OK'
    assert 'live/church242' in rows[0]['detail']
    assert '192.168.1.50' in rows[0]['detail']


def test_check_publishers_key_mismatch_warns(monkeypatch):
    monkeypatch.setattr(kiosk_manager, '_fetch_stat', lambda: STAT_XML_MISMATCH)
    monkeypatch.setattr(kiosk_manager, '_stream_key', lambda: 'church242')
    rows = kiosk_manager._check_publishers()
    assert len(rows) == 1
    assert rows[0]['status'] == 'WARN'
    assert 'wrongkey' in rows[0]['detail']
    assert 'church242' in rows[0]['detail']


def test_check_publishers_none_connected(monkeypatch):
    monkeypatch.setattr(kiosk_manager, '_fetch_stat', lambda: STAT_XML_IDLE)
    monkeypatch.setattr(kiosk_manager, '_stream_key', lambda: 'church242')
    rows = kiosk_manager._check_publishers()
    assert len(rows) == 1
    assert rows[0]['status'] == 'OK'
    assert rows[0]['detail'] == 'none'


def test_check_publishers_stat_unreachable(monkeypatch):
    monkeypatch.setattr(kiosk_manager, '_fetch_stat', lambda: None)
    rows = kiosk_manager._check_publishers()
    assert len(rows) == 1
    assert rows[0]['status'] == 'WARN'


def test_status_board_includes_stream_rows(client):
    body = client.get(f'/api/status?token={TEST_TOKEN}').get_json()
    labels = {c['label'] for c in body['checks']}
    assert 'Player Stream' in labels
    assert any(lbl.startswith('Publisher') for lbl in labels)


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


# ── token store & rotation ───────────────────────────────────────────────────

def test_current_token_prefers_state_file(tmp_path, monkeypatch):
    tf = tmp_path / 'token'
    tf.write_text('file-token\n')
    monkeypatch.setattr(kiosk_manager, 'TOKEN_FILE', tf)
    monkeypatch.setattr(kiosk_manager, 'TOKEN', 'seed-token')
    assert kiosk_manager.current_token() == 'file-token'


def test_current_token_falls_back_to_seed(tmp_path, monkeypatch):
    monkeypatch.setattr(kiosk_manager, 'TOKEN_FILE', tmp_path / 'nope')
    monkeypatch.setattr(kiosk_manager, 'TOKEN', 'seed-token')
    assert kiosk_manager.current_token() == 'seed-token'


def test_current_token_ignores_empty_state_file(tmp_path, monkeypatch):
    tf = tmp_path / 'token'
    tf.write_text('   \n')
    monkeypatch.setattr(kiosk_manager, 'TOKEN_FILE', tf)
    monkeypatch.setattr(kiosk_manager, 'TOKEN', 'seed-token')
    assert kiosk_manager.current_token() == 'seed-token'


def test_write_token_atomic_and_perms(tmp_path, monkeypatch):
    import os as _os
    import stat as _stat
    state = tmp_path / 'state'
    tf = state / 'token'
    monkeypatch.setattr(kiosk_manager, 'STATE_DIR', state)
    monkeypatch.setattr(kiosk_manager, 'TOKEN_FILE', tf)
    kiosk_manager._write_token('hello')
    assert tf.read_text().strip() == 'hello'
    assert _stat.S_IMODE(_os.stat(tf).st_mode) == 0o600


def test_rotate_requires_token(client):
    r = client.post('/api/token/rotate')
    assert r.status_code == 403


def test_rotate_changes_token_and_invalidates_old(client, tmp_path, monkeypatch):
    tf = tmp_path / 'token'
    monkeypatch.setattr(kiosk_manager, 'STATE_DIR', tmp_path)
    monkeypatch.setattr(kiosk_manager, 'TOKEN_FILE', tf)
    r = client.post(f'/api/token/rotate?token={TEST_TOKEN}')
    assert r.status_code == 200
    body = r.get_json()
    new = body['token']
    assert new and new != TEST_TOKEN
    assert tf.read_text().strip() == new
    assert new in body['url']
    # The admin's own session now holds a cookie re-keyed to the new token, so
    # drop it to model a *different* device that only ever had the old link:
    # that stale link no longer works, and the new one does.
    client.delete_cookie(kiosk_manager.COOKIE_NAME)
    assert client.get(f'/?token={TEST_TOKEN}').status_code == 403
    assert client.get(f'/?token={new}').status_code == 200


# ── external URL resolution ──────────────────────────────────────────────────

def test_volunteer_url_prefers_public_url(monkeypatch):
    monkeypatch.setenv('PUBLIC_URL', 'https://kiosk.church.org')
    with kiosk_manager.app.test_request_context('http://10.0.0.5/'):
        assert kiosk_manager._volunteer_url('ABC') == 'https://kiosk.church.org/?token=ABC'


def test_volunteer_url_falls_back_to_request_host(monkeypatch):
    monkeypatch.delenv('PUBLIC_URL', raising=False)
    with kiosk_manager.app.test_request_context('http://displaypi.local/'):
        assert kiosk_manager._volunteer_url('XYZ') == 'http://displaypi.local/?token=XYZ'


# ── shortcut file downloads ──────────────────────────────────────────────────

def test_webloc_download(client):
    r = client.get(f'/api/token/webloc?token={TEST_TOKEN}')
    assert r.status_code == 200
    assert 'attachment' in r.headers.get('Content-Disposition', '')
    body = r.get_data(as_text=True)
    assert '<plist' in body
    assert TEST_TOKEN in body


def test_urlfile_download(client):
    r = client.get(f'/api/token/url?token={TEST_TOKEN}')
    assert r.status_code == 200
    body = r.get_data(as_text=True)
    assert body.startswith('[InternetShortcut]')
    assert TEST_TOKEN in body


def test_token_info_json(client):
    body = client.get(f'/api/token?token={TEST_TOKEN}').get_json()
    assert body['token'] == TEST_TOKEN
    assert TEST_TOKEN in body['url']


# ── uptime humanizer ─────────────────────────────────────────────────────────

def test_humanize_uptime_minutes():
    assert kiosk_manager._humanize_uptime(90) == 'up 1 minute'


def test_humanize_uptime_hours_and_days():
    # 2 days, 3 hours, 4 minutes
    secs = 2 * 86400 + 3 * 3600 + 4 * 60
    out = kiosk_manager._humanize_uptime(secs)
    assert out == 'up 2 days, 3 hours, 4 minutes'
