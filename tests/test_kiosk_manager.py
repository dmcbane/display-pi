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
