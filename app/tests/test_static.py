from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from reelops_api.main import create_app


@pytest.fixture
def ui_client(settings, aws, tmp_path):
    (tmp_path / "index.html").write_text("<!doctype html><title>ReelOps</title>")
    (tmp_path / "assets").mkdir()
    (tmp_path / "assets" / "index-abc123.js").write_text("console.log('hi')")
    (tmp_path / "favicon.svg").write_text("<svg/>")
    (tmp_path / "assets" / "font-abc123.woff2").write_bytes(b"wOF2")
    s3, table = aws
    return TestClient(create_app(replace(settings, static_dir=str(tmp_path)), s3=s3, table=table))


def test_root_and_page_paths_serve_the_app(ui_client):
    for path in ["/", "/some/page"]:
        r = ui_client.get(path)
        assert r.status_code == 200
        assert "<title>ReelOps</title>" in r.text
        assert r.headers["cache-control"] == "no-cache"


def test_hashed_assets_are_cached_forever(ui_client):
    r = ui_client.get("/assets/index-abc123.js")
    assert r.status_code == 200
    assert r.headers["cache-control"] == "public, max-age=31536000, immutable"
    assert ui_client.get("/favicon.svg").headers["cache-control"] == "no-cache"


def test_missing_asset_is_a_real_404_not_html(ui_client):
    r = ui_client.get("/assets/old-999.js")
    assert r.status_code == 404
    assert "<title>" not in r.text


def test_api_routes_take_priority(ui_client):
    assert ui_client.get("/healthz").json() == {"status": "ok"}
    r = ui_client.get("/jobs/00000000-0000-4000-8000-000000000000")
    assert r.status_code == 404
    assert r.json() == {"detail": "job not found"}  # JSON from the API, not index.html


def test_without_static_dir_root_is_404(client):
    assert client.get("/").status_code == 404


def test_fonts_have_font_content_types(ui_client):
    assert ui_client.get("/assets/font-abc123.woff2").headers["content-type"] == "font/woff2"
