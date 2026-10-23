"""Runs stages a -> e in a temporary working directory."""

from __future__ import annotations

import logging
import shutil
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from . import PipelineError, ffmpeg
from .audio import extract_audio
from .captions import write_srt
from .config import Settings
from .render import render
from .transcribe import load_model, transcribe
from .voiceover import build_voiceover

log = logging.getLogger(__name__)


@contextmanager
def _stage(name: str, timings: dict[str, float]):
    log.info("stage %s: started", name)
    start = time.perf_counter()
    yield
    timings[name] = time.perf_counter() - start
    log.info("stage %s: done in %.1fs", name, timings[name])


def run(video: Path, out_mp4: Path, settings: Settings, *, model=None, polly=None) -> Path:
    """Turn `video` into a captioned, voiced video at out_mp4 and return it.

    Pass a pre-loaded Whisper `model` or a Polly client to reuse them across
    jobs; otherwise they are created here.
    """
    timings: dict[str, float] = {}
    started = time.perf_counter()

    # TemporaryDirectory is removed on exit, including when a stage raises.
    with tempfile.TemporaryDirectory(prefix="reelops-") as tmp:
        work = Path(tmp)

        if not ffmpeg.has_stream(video, "video", untrusted=True):
            raise PipelineError(f"{video.name} has no video stream")
        duration = ffmpeg.duration(video, untrusted=True)
        log.info("input: %s (%.1fs)", video.name, duration)

        with _stage("audio", timings):
            wav = extract_audio(video, work / "audio.wav")

        if model is None:
            with _stage("load_model", timings):
                model = load_model(settings)

        with _stage("transcribe", timings):
            segments = transcribe(wav, settings, model)
        if not segments:
            raise PipelineError(f"no speech detected in {video.name}")

        with _stage("captions", timings):
            srt = write_srt(segments, work / "captions.srt", settings.caption_max_chars, settings.caption_max_lines)

        with _stage("voiceover", timings):
            voice = build_voiceover(segments, duration, work, work / "voiceover.wav", settings, polly)

        with _stage("render", timings):
            rendered = render(video, srt, voice, work / "output.mp4")

        # Move into place only once complete, so a half-written file never
        # appears at the output path.
        out_mp4.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(rendered, out_mp4)

    total = time.perf_counter() - started
    summary = ", ".join(f"{name}={secs:.1f}s" for name, secs in timings.items())
    log.info("done: %s (%.1fs) in %.1fs [%s]", out_mp4, ffmpeg.duration(out_mp4), total, summary)
    return out_mp4
