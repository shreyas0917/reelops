"""API settings, read once from environment variables."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# Allowed uploads: file extension -> the Content-Type the upload must use.
ALLOWED_TYPES = {
    "mp4": "video/mp4",
    "mov": "video/quicktime",
    "webm": "video/webm",
}


@dataclass(frozen=True)
class Settings:
    media_bucket: str
    jobs_table: str
    aws_region: str = "ap-south-1"
    max_upload_bytes: int = 200 * 1024 * 1024  # 200 MB
    url_expiry_seconds: int = 15 * 60  # presigned URL lifetime
    job_ttl_seconds: int = 7 * 24 * 3600  # DynamoDB expires_at

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env

        def required(name: str) -> str:
            value = env.get(name, "").strip()
            if not value:
                raise ValueError(f"{name} must be set (see scripts/env_from_tf.sh)")
            return value

        return cls(
            media_bucket=required("REELOPS_MEDIA_BUCKET"),
            jobs_table=required("REELOPS_JOBS_TABLE"),
            aws_region=(env.get("AWS_REGION") or env.get("AWS_DEFAULT_REGION") or "ap-south-1").strip(),
        )
