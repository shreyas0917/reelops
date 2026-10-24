import time
from decimal import Decimal
from urllib.parse import parse_qs, urlparse

import pytest

from reelops_api.jobs import MAX_FILENAME_CHARS, display_filename

VALID = {"filename": "demo.mp4", "content_type": "video/mp4", "size": 5_000_000}


def test_healthz(client):
    assert client.get("/healthz").json() == {"status": "ok"}


def test_create_job_stores_pending_item_and_returns_presigned_put(client, table, settings):
    before = int(time.time())
    r = client.post("/jobs", json=VALID)
    assert r.status_code == 201
    body = r.json()
    job_id = body["job_id"]

    item = table.get_item(Key={"job_id": job_id})["Item"]
    assert item["status"] == "pending"
    assert item["s3_key"] == f"raw/{job_id}/input.mp4"
    assert item["attempts"] == 0
    assert item["created_at"] >= before
    assert item["expires_at"] == item["created_at"] + 7 * 24 * 3600

    url = urlparse(body["upload_url"])
    query = parse_qs(url.query)
    assert url.netloc == f"{settings.media_bucket}.s3.ap-south-1.amazonaws.com"  # regional
    assert url.path == f"/raw/{job_id}/input.mp4"
    assert query["X-Amz-Expires"] == ["900"]
    assert "content-type" in query["X-Amz-SignedHeaders"][0].split(";")
    assert body["upload_method"] == "PUT"
    assert body["upload_headers"] == {"Content-Type": "video/mp4"}


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ({"filename": "demo.avi", "content_type": "video/x-msvideo", "size": 10}, "unsupported file type"),
        ({"filename": "demo.mov", "content_type": "video/mp4", "size": 10}, "must be video/quicktime"),
        ({"filename": "demo.mp4", "content_type": "video/mp4", "size": 200 * 1024 * 1024 + 1}, "too large"),
    ],
)
def test_create_job_rejects_bad_uploads(client, table, payload, message):
    r = client.post("/jobs", json=payload)
    assert r.status_code == 422
    assert message in r.json()["detail"]
    assert table.scan()["Count"] == 0  # nothing written


def test_mov_and_webm_are_allowed(client):
    for filename, content_type in [("a.MOV", "video/quicktime"), ("b.webm", "video/webm")]:
        r = client.post("/jobs", json={"filename": filename, "content_type": content_type, "size": 10})
        assert r.status_code == 201, r.text
        assert r.json()["upload_url"].split("?")[0].endswith(f"/input.{filename.rsplit('.', 1)[1].lower()}")


def test_filename_is_stored_sanitized_and_returned(client, table):
    payload = {**VALID, "filename": "C:\\Users\\me\\Q3  demo\u202e4pm.mp4"}
    job_id = client.post("/jobs", json=payload).json()["job_id"]
    assert table.get_item(Key={"job_id": job_id})["Item"]["filename"] == "Q3 demo4pm.mp4"
    assert client.get(f"/jobs/{job_id}").json()["filename"] == "Q3 demo4pm.mp4"


@pytest.mark.parametrize(
    ("raw", "shown"),
    [
        ("demo.mp4", "demo.mp4"),
        ("folder/sub/demo.mov", "demo.mov"),  # browsers send a bare name, but don't trust it
        ("line\nbreak\t.webm", "line break .webm"),
        ("cafe\u0301.mp4", "caf\u00e9.mp4"),  # NFC: one code point for é
        ("zero\u200bwidth.mp4", "zerowidth.mp4"),
    ],
)
def test_display_filename(raw, shown):
    assert display_filename(raw) == shown


def test_long_filename_is_cut_keeping_the_extension():
    shown = display_filename("a" * 300 + ".webm")
    assert len(shown) == MAX_FILENAME_CHARS
    assert shown.endswith("….webm")


def test_job_without_stored_filename_returns_null(client, table):
    job_id = client.post("/jobs", json=VALID).json()["job_id"]
    table.update_item(Key={"job_id": job_id}, UpdateExpression="REMOVE filename")  # as created before this change
    assert client.get(f"/jobs/{job_id}").json()["filename"] is None


def test_get_pending_job_has_no_download_url(client):
    job_id = client.post("/jobs", json=VALID).json()["job_id"]
    body = client.get(f"/jobs/{job_id}").json()
    assert body["status"] == "pending"
    assert body["download_url"] is None
    assert body["preview_url"] is None
    assert body["original_preview_url"] is None
    assert (body["segments"], body["voice"]) == ([], None)
    assert body["error"] is None


def test_get_done_job_has_presigned_attachment_download(client, table):
    job_id = client.post("/jobs", json=VALID).json()["job_id"]
    table.update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET #s = :done",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":done": "done"},
    )
    body = client.get(f"/jobs/{job_id}").json()
    # Same object, two signed links: attachment (download) and inline (<video>).
    for field, disposition in [("download_url", "attachment"), ("preview_url", "inline")]:
        url = urlparse(body[field])
        query = parse_qs(url.query)
        assert url.path == f"/output/{job_id}.mp4"
        assert query["X-Amz-Expires"] == ["900"]
        assert query["response-content-disposition"] == [f'{disposition}; filename="reelops-{job_id}.mp4"']


def test_done_job_returns_segments_voice_and_original_preview(client, table):
    job_id = client.post("/jobs", json=VALID).json()["job_id"]
    # As the worker stores them: DynamoDB numbers come back as Decimal.
    segments = [
        {"start": Decimal("0.5"), "end": Decimal("2.25"), "text": "Welcome to ReelOps."},
        {"start": Decimal("2.25"), "end": Decimal("4.123"), "text": "Upload a recording."},
    ]
    table.update_item(
        Key={"job_id": job_id},
        # "segments" is a DynamoDB reserved word, so it needs a placeholder too.
        UpdateExpression="SET #s = :done, #segs = :segs, voice = :voice",
        ExpressionAttributeNames={"#s": "status", "#segs": "segments"},
        ExpressionAttributeValues={":done": "done", ":segs": segments, ":voice": "Kajal"},
    )
    body = client.get(f"/jobs/{job_id}").json()
    assert body["segments"] == [
        {"start": 0.5, "end": 2.25, "text": "Welcome to ReelOps."},
        {"start": 2.25, "end": 4.123, "text": "Upload a recording."},
    ]
    assert body["voice"] == "Kajal"
    # The raw upload, signed for inline playback (the UI's "Original" toggle).
    url = urlparse(body["original_preview_url"])
    assert url.path == f"/raw/{job_id}/input.mp4"
    assert parse_qs(url.query)["response-content-disposition"] == [f'inline; filename="original-{job_id}.mp4"']


def test_failed_job_reports_error(client, table):
    job_id = client.post("/jobs", json=VALID).json()["job_id"]
    table.update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET #s = :f, #e = :e",
        ExpressionAttributeNames={"#s": "status", "#e": "error"},
        ExpressionAttributeValues={":f": "failed", ":e": "input.mp4 has no audio stream"},
    )
    body = client.get(f"/jobs/{job_id}").json()
    assert (body["status"], body["error"], body["download_url"], body["preview_url"]) == (
        "failed",
        "input.mp4 has no audio stream",
        None,
        None,
    )


def test_unknown_and_malformed_ids(client):
    assert client.get("/jobs/00000000-0000-4000-8000-000000000000").status_code == 404
    assert client.get("/jobs/not-a-uuid").status_code == 422


def test_expired_job_is_not_found(client, table):
    # TTL deletes lazily, so an expired item may still exist; the API hides it.
    job_id = client.post("/jobs", json=VALID).json()["job_id"]
    table.update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET expires_at = :past",
        ExpressionAttributeValues={":past": int(time.time()) - 1},
    )
    assert client.get(f"/jobs/{job_id}").status_code == 404
