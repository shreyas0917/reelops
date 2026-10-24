"""Job logic: create jobs with presigned uploads, read status with presigned downloads.

Clients (S3 client, DynamoDB Table) are passed in, so tests can use moto.
"""

from __future__ import annotations

import re
import time
import unicodedata
import uuid
from decimal import Decimal

import boto3
from botocore.config import Config

from .config import ALLOWED_TYPES, Settings


class InvalidUpload(ValueError):
    """The requested upload isn't allowed (type, extension or size)."""


class JobNotFound(LookupError):
    pass


def make_s3_client(region: str):
    # SigV4 on the regional virtual-hosted endpoint
    # (https://<bucket>.s3.<region>.amazonaws.com): the global endpoint can
    # answer with a 307 redirect, which breaks browser CORS preflights.
    return boto3.client(
        "s3",
        region_name=region,
        config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
    )


def raw_key(job_id: str, ext: str) -> str:
    return f"raw/{job_id}/input.{ext}"


def output_key(job_id: str) -> str:
    return f"output/{job_id}.mp4"


MAX_FILENAME_CHARS = 120


def display_filename(filename: str) -> str:
    """The upload's name as shown in the UI and on shared links.

    Only a label (React escapes it; it's never a path or a header), but it
    reaches anyone with the link, so: no directory parts, no control or
    format characters (e.g. right-to-left overrides that disguise a name),
    collapsed whitespace, NFC, and a length cap that keeps the extension.
    """
    name = unicodedata.normalize("NFC", filename).replace("\\", "/").rsplit("/", 1)[-1]
    name = re.sub(r"\s+", " ", name)  # first, so tabs/newlines become spaces, not nothing
    name = "".join(ch for ch in name if unicodedata.category(ch) not in ("Cc", "Cf", "Cs", "Co", "Cn")).strip()
    if len(name) > MAX_FILENAME_CHARS:
        stem, dot, ext = name.rpartition(".")
        keep = f"{dot}{ext}" if dot and len(ext) <= 10 else ""
        name = name[: MAX_FILENAME_CHARS - len(keep) - 1].rstrip() + "…" + keep
    return name


def validate_upload(filename: str, content_type: str, size: int, settings: Settings) -> str:
    """Return the file extension if the upload is allowed, else raise InvalidUpload."""
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    expected = ALLOWED_TYPES.get(ext)
    if expected is None:
        allowed = ", ".join(f".{e}" for e in ALLOWED_TYPES)
        raise InvalidUpload(f"unsupported file type; allowed: {allowed}")
    if content_type != expected:
        raise InvalidUpload(f"content_type for .{ext} files must be {expected}")
    if size > settings.max_upload_bytes:
        raise InvalidUpload(f"file too large: {size} bytes (max {settings.max_upload_bytes})")
    return ext


def create_job(filename: str, content_type: str, size: int, *, settings: Settings, table, s3) -> dict:
    """Create a pending job and return its id plus a presigned PUT URL."""
    ext = validate_upload(filename, content_type, size, settings)
    job_id = str(uuid.uuid4())
    key = raw_key(job_id, ext)
    now = int(time.time())

    # Never overwrite an existing job, however unlikely a uuid4 collision is.
    table.put_item(
        Item={
            "job_id": job_id,
            "status": "pending",
            "s3_key": key,
            "filename": display_filename(filename),
            "attempts": 0,
            "created_at": now,
            "updated_at": now,
            "expires_at": now + settings.job_ttl_seconds,
        },
        ConditionExpression="attribute_not_exists(job_id)",
    )

    # The Content-Type is part of the signature: the PUT must send exactly
    # this header or S3 rejects it. Size can't be enforced by a presigned PUT;
    # the worker re-checks the real object size (production upgrade:
    # presigned POST with a content-length-range condition).
    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": settings.media_bucket, "Key": key, "ContentType": content_type},
        ExpiresIn=settings.url_expiry_seconds,
    )
    return {
        "job_id": job_id,
        "upload_url": upload_url,
        "upload_method": "PUT",
        "upload_headers": {"Content-Type": content_type},
        "expires_in": settings.url_expiry_seconds,
    }


def _plain(value):
    """DynamoDB returns numbers as Decimal; convert for JSON."""
    return int(value) if isinstance(value, Decimal) else value


def _segments(item: dict) -> list[dict]:
    """Caption segments the worker stored with "done" (times are Decimals)."""
    return [
        {"start": float(s["start"]), "end": float(s["end"]), "text": s["text"]} for s in item.get("segments", [])
    ]


def get_job(job_id: str, *, settings: Settings, table, s3) -> dict:
    """Return job status; adds captions, voice and presigned URLs once done."""
    # Consistent read: a poller sees "done" as soon as the worker writes it.
    item = table.get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item")
    # TTL deletion is lazy, so treat expired items as already gone.
    if not item or int(item.get("expires_at", 0)) <= time.time():
        raise JobNotFound(job_id)

    job = {
        "job_id": job_id,
        "status": item["status"],
        "filename": item.get("filename"),  # None for jobs created before it was stored
        "error": item.get("error"),
        "attempts": _plain(item.get("attempts", 0)),
        "created_at": _plain(item["created_at"]),
        "updated_at": _plain(item["updated_at"]),
        "download_url": None,
        "preview_url": None,
        "original_preview_url": None,
        "segments": _segments(item),
        "voice": item.get("voice"),
    }
    if job["status"] == "done":
        # Same object, two signed links: the disposition is part of the
        # signature. attachment = browser saves it; inline = <video> plays it.
        job["download_url"] = _signed_get_url(output_key(job_id), "attachment", f"reelops-{job_id}.mp4", settings, s3)
        job["preview_url"] = _signed_get_url(output_key(job_id), "inline", f"reelops-{job_id}.mp4", settings, s3)
        # The raw upload, for the UI's "Original" toggle. Only once done, like
        # the output links: before that the upload may not exist yet.
        raw = item["s3_key"]
        ext = raw.rsplit(".", 1)[-1]
        job["original_preview_url"] = _signed_get_url(raw, "inline", f"original-{job_id}.{ext}", settings, s3)
    return job


def _signed_get_url(key: str, disposition: str, filename: str, settings: Settings, s3) -> str:
    return s3.generate_presigned_url(
        "get_object",
        Params={
            "Bucket": settings.media_bucket,
            "Key": key,
            "ResponseContentDisposition": f'{disposition}; filename="{filename}"',
        },
        ExpiresIn=settings.url_expiry_seconds,
    )
