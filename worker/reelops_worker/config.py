"""Worker settings, read once from environment variables.

Stages receive a Settings object as an argument instead of reading the
environment themselves, so the CLI, the Phase 3 queue consumer and the tests
can each build Settings their own way.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    # Transcription (faster-whisper)
    whisper_model: str = "base"
    whisper_device: str = "cpu"
    whisper_compute_type: str = "int8"
    # Directory holding downloaded models; None means the Hugging Face cache.
    # The Docker image bakes the model in and points this at it.
    whisper_model_dir: str | None = None
    # Spoken language of the input; None lets Whisper auto-detect.
    language: str | None = "en"
    # Words Whisper should prefer when the audio is ambiguous, e.g. product
    # names it would otherwise split ("ReelOps" -> "Reel Ops"). None = no hint.
    whisper_hotwords: str | None = None

    # Voice-over (Amazon Polly)
    polly_voice: str = "Kajal"
    polly_language: str = "en-IN"
    polly_fallback_voice: str = "Joanna"
    polly_engine: str = "neural"
    # Cap on how much a clip may be sped up to fit its caption slot.
    max_speedup: float = 1.5

    # Captions
    caption_max_chars: int = 42
    caption_max_lines: int = 2

    aws_region: str = "ap-south-1"

    # Queue consumer (python -m reelops_worker consume). Unused by the CLI.
    jobs_queue_url: str | None = None
    media_bucket: str | None = None
    jobs_table: str | None = None
    max_input_bytes: int = 200 * 1024 * 1024
    # Must match the SQS queue (terraform/main/sqs.tf).
    visibility_timeout: int = 300
    # Real attempts (claims, counted on the job item) before a job is given up.
    # Not SQS's receive count: that also counts harmless releases (scale-in,
    # SIGTERM hand-backs). The queue's maxReceiveCount (10) is only a backstop
    # for messages that are never claimed.
    max_attempts: int = 3
    heartbeat_seconds: int = 60
    # Shorter than the visibility timeout on purpose: a dead worker's lease must
    # be stale before its message reappears, or the redelivery would see a
    # "fresh" lease, drop the message, and the job would be stuck.
    lease_seconds: int = 240
    # How long a job may keep running after SIGTERM before it's handed back.
    # Below ECS's default 30 s stop timeout.
    shutdown_grace_seconds: int = 20
    # ECS task scale-in protection expiry while holding a job (ECS allows
    # 1-2880). Covers a 200 MB video; lapses by itself if a worker dies.
    task_protection_minutes: int = 60

    def __post_init__(self) -> None:
        if not self.heartbeat_seconds < self.lease_seconds < self.visibility_timeout:
            raise ValueError(
                "need heartbeat_seconds < lease_seconds < visibility_timeout, got "
                f"{self.heartbeat_seconds} / {self.lease_seconds} / {self.visibility_timeout}"
            )
        if not 1.0 <= self.max_speedup <= 2.0:
            raise ValueError(
                f"REELOPS_MAX_SPEEDUP must be between 1.0 and 2.0, got {self.max_speedup}"
            )
        if not 1 <= self.task_protection_minutes <= 2880:
            raise ValueError(f"task_protection_minutes must be 1-2880, got {self.task_protection_minutes}")
        if self.caption_max_chars < 10:
            raise ValueError(
                f"REELOPS_CAPTION_MAX_CHARS must be at least 10, got {self.caption_max_chars}"
            )
        if self.caption_max_lines < 1:
            raise ValueError(
                f"REELOPS_CAPTION_MAX_LINES must be at least 1, got {self.caption_max_lines}"
            )

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        """Build Settings from environment variables, falling back to defaults."""
        env = os.environ if env is None else env
        d = cls()  # defaults

        def get(name: str, default: str | None) -> str | None:
            value = env.get(name, "").strip()
            return value or default

        def get_number(name: str, default: float, kind: type) -> float:
            raw = get(name, None)
            if raw is None:
                return default
            try:
                return kind(raw)
            except ValueError:
                raise ValueError(f"{name} must be a {kind.__name__}, got {raw!r}") from None

        language = get("REELOPS_LANGUAGE", d.language)
        return cls(
            whisper_model=get("REELOPS_WHISPER_MODEL", d.whisper_model),
            whisper_device=get("REELOPS_WHISPER_DEVICE", d.whisper_device),
            whisper_compute_type=get("REELOPS_WHISPER_COMPUTE_TYPE", d.whisper_compute_type),
            whisper_model_dir=get("REELOPS_WHISPER_MODEL_DIR", d.whisper_model_dir),
            whisper_hotwords=get("REELOPS_WHISPER_HOTWORDS", d.whisper_hotwords),
            # "auto" means let Whisper detect the language.
            language=None if language == "auto" else language,
            polly_voice=get("REELOPS_POLLY_VOICE", d.polly_voice),
            polly_language=get("REELOPS_POLLY_LANGUAGE", d.polly_language),
            polly_fallback_voice=get("REELOPS_POLLY_FALLBACK_VOICE", d.polly_fallback_voice),
            polly_engine=get("REELOPS_POLLY_ENGINE", d.polly_engine),
            max_speedup=get_number("REELOPS_MAX_SPEEDUP", d.max_speedup, float),
            caption_max_chars=get_number("REELOPS_CAPTION_MAX_CHARS", d.caption_max_chars, int),
            caption_max_lines=get_number("REELOPS_CAPTION_MAX_LINES", d.caption_max_lines, int),
            aws_region=get("AWS_REGION", None) or get("AWS_DEFAULT_REGION", d.aws_region),
            jobs_queue_url=get("REELOPS_JOBS_QUEUE_URL", None),
            media_bucket=get("REELOPS_MEDIA_BUCKET", None),
            jobs_table=get("REELOPS_JOBS_TABLE", None),
        )

    def require_consumer(self) -> None:
        """Raise if settings needed by the queue consumer are missing."""
        missing = [
            name
            for name, value in [
                ("REELOPS_JOBS_QUEUE_URL", self.jobs_queue_url),
                ("REELOPS_MEDIA_BUCKET", self.media_bucket),
                ("REELOPS_JOBS_TABLE", self.jobs_table),
            ]
            if not value
        ]
        if missing:
            raise ValueError(f"consumer mode needs {', '.join(missing)} (see scripts/env_from_tf.sh)")
