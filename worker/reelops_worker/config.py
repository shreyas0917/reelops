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

    def __post_init__(self) -> None:
        if not 1.0 <= self.max_speedup <= 2.0:
            raise ValueError(
                f"REELOPS_MAX_SPEEDUP must be between 1.0 and 2.0, got {self.max_speedup}"
            )
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
        )
