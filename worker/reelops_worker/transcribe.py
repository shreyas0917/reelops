"""Stage b: speech-to-text with faster-whisper."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

from faster_whisper import WhisperModel

from .config import Settings

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class Segment:
    """One stretch of speech, in seconds from the start of the video."""

    start: float
    end: float
    text: str


def load_model(settings: Settings) -> WhisperModel:
    """Load the Whisper model. Slow (seconds), so long-running callers such as
    the Phase 3 queue consumer should load once and pass it to transcribe().
    """
    return WhisperModel(
        settings.whisper_model,
        device=settings.whisper_device,
        compute_type=settings.whisper_compute_type,
        download_root=settings.whisper_model_dir,
    )


def transcribe(wav: Path, settings: Settings, model: WhisperModel | None = None) -> list[Segment]:
    """Transcribe a 16 kHz mono WAV and return its speech segments in order."""
    model = model or load_model(settings)
    # vad_filter skips silence, which is faster and stops Whisper from
    # hallucinating text over quiet stretches.
    raw_segments, info = model.transcribe(
        str(wav), language=settings.language, vad_filter=True, hotwords=settings.whisper_hotwords
    )
    # raw_segments is a lazy generator: the actual transcription happens here.
    segments = [Segment(s.start, s.end, s.text.strip()) for s in raw_segments if s.text.strip()]
    log.info(
        "transcribed %d segments, language=%s (p=%.2f), speech=%.1fs of %.1fs",
        len(segments),
        info.language,
        info.language_probability,
        info.duration_after_vad,
        info.duration,
    )
    return segments
