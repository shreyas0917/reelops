"""Job logic: create jobs with presigned uploads, read status with presigned downloads.

Clients (S3 client, DynamoDB Table) are passed in, so tests can use moto.
"""

from __future__ import annotations

import time
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


def get_job(job_id: str, *, settings: Settings, table, s3) -> dict:
    """Return job status; adds a presigned download URL once the job is done."""
    # Consistent read: a poller sees "done" as soon as the worker writes it.
    item = table.get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item")
    # TTL deletion is lazy, so treat expired items as already gone.
    if not item or int(item.get("expires_at", 0)) <= time.time():
        raise JobNotFound(job_id)

    job = {
        "job_id": job_id,
        "status": item["status"],
        "error": item.get("error"),
        "attempts": _plain(item.get("attempts", 0)),
        "created_at": _plain(item["created_at"]),
        "updated_at": _plain(item["updated_at"]),
        "download_url": None,
    }
    if job["status"] == "done":
        job["download_url"] = s3.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": settings.media_bucket,
                "Key": output_key(job_id),
                # Browser saves the file instead of playing it in the tab.
                "ResponseContentDisposition": f'attachment; filename="reelops-{job_id}.mp4"',
            },
            ExpiresIn=settings.url_expiry_seconds,
        )
    return job
