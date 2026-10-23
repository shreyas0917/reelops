"""Stage d: synthesize an AI voice-over with Amazon Polly, synced to segments.

The video is unchanged, so the new voice must say each sentence when the
original speaker did. Synthesizing the whole script as one clip would drift
out of sync, so each segment becomes its own clip, anchored at its start time
and sped up (within limits) to fit before the next segment begins.
"""

from __future__ import annotations

import logging
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from . import PipelineError, ffmpeg
from .config import Settings
from .transcribe import Segment

log = logging.getLogger(__name__)

SAMPLE_RATE = 24000  # Polly neural's native mp3 rate
OVERRUN_WARN_SECONDS = 0.05


@dataclass(frozen=True)
class Fit:
    tempo: float  # atempo factor to apply (1.0 = unchanged)
    overrun: float  # seconds the clip still runs past its slot after speed-up


def slots(segments: list[Segment], duration: float) -> list[float]:
    """Time available to each segment's clip: from its start to the next
    segment's start (or the end of the video for the last one).
    """
    starts = [s.start for s in segments]
    ends = starts[1:] + [duration]
    return [max(0.0, end - start) for start, end in zip(starts, ends)]


def fit_to_slot(clip: float, slot: float, max_speedup: float) -> Fit:
    """How much to speed up a clip of `clip` seconds to fit `slot` seconds."""
    if clip <= slot:
        return Fit(1.0, 0.0)
    if slot <= 0:
        return Fit(max_speedup, clip / max_speedup)
    tempo = min(clip / slot, max_speedup)
    return Fit(tempo, max(0.0, clip / tempo - slot))


@contextmanager
def _polly_errors(action: str):
    try:
        yield
    except (BotoCoreError, ClientError) as exc:
        raise PipelineError(f"Polly {action} failed: {exc}") from exc


def resolve_voice(polly, settings: Settings) -> tuple[str, str | None]:
    """Pick the configured voice, or the fallback if it isn't available for
    this engine and region. Returns (voice_id, language_code or None).
    """
    voices: dict[str, dict] = {}
    kwargs = {"Engine": settings.polly_engine}
    with _polly_errors("DescribeVoices"):
        while True:
            page = polly.describe_voices(**kwargs)
            voices.update({v["Id"]: v for v in page["Voices"]})
            if not page.get("NextToken"):
                break
            kwargs["NextToken"] = page["NextToken"]

    for voice_id in (settings.polly_voice, settings.polly_fallback_voice):
        voice = voices.get(voice_id)
        if voice is None:
            continue
        if voice_id != settings.polly_voice:
            log.warning(
                "voice %s is not available for engine=%s in %s; falling back to %s",
                settings.polly_voice,
                settings.polly_engine,
                settings.aws_region,
                voice_id,
            )
        # Only pass a LanguageCode the voice supports (e.g. Kajal: en-IN/hi-IN).
        languages = {voice["LanguageCode"], *voice.get("AdditionalLanguageCodes", [])}
        language = settings.polly_language if settings.polly_language in languages else None
        return voice_id, language

    raise PipelineError(
        f"neither {settings.polly_voice} nor {settings.polly_fallback_voice} is available "
        f"for engine={settings.polly_engine} in {settings.aws_region}"
    )


def synthesize(polly, text: str, voice_id: str, language: str | None, engine: str, out_mp3: Path) -> Path:
    """Synthesize `text` to an mp3 file and return its path."""
    extra = {"LanguageCode": language} if language else {}
    with _polly_errors("SynthesizeSpeech"):
        response = polly.synthesize_speech(
            Text=text,
            VoiceId=voice_id,
            Engine=engine,
            OutputFormat="mp3",
            SampleRate=str(SAMPLE_RATE),
            **extra,
        )
        with response["AudioStream"] as stream:
            out_mp3.write_bytes(stream.read())
    return out_mp3


def _mix(placed: list[tuple[float, Path]], duration: float, out_wav: Path) -> None:
    """Mix (start_seconds, clip) pairs onto silence exactly `duration` long."""
    inputs = ["-f", "lavfi", "-t", f"{duration:.3f}", "-i", f"anullsrc=r={SAMPLE_RATE}:cl=mono"]
    chains, labels = [], ["[0:a]"]
    for n, (start, clip) in enumerate(placed, start=1):
        inputs += ["-i", clip]
        chains.append(f"[{n}:a]adelay={round(start * 1000)}:all=1[a{n}]")
        labels.append(f"[a{n}]")
    # duration=first: output is exactly as long as the silent base track.
    # normalize=0: don't turn every clip down by 1/N.
    chains.append(f"{''.join(labels)}amix=inputs={len(labels)}:duration=first:normalize=0[out]")
    ffmpeg.run(
        [
            *inputs,
            "-filter_complex", ";".join(chains),
            "-map", "[out]",
            "-ac", "1", "-ar", str(SAMPLE_RATE), "-c:a", "pcm_s16le",
            out_wav,
        ]
    )  # fmt: skip


def build_voiceover(
    segments: list[Segment],
    duration: float,
    workdir: Path,
    out_wav: Path,
    settings: Settings,
    polly=None,
) -> Path:
    """Synthesize one clip per segment, place each at its segment start, and
    mix them into a single WAV of exactly `duration` seconds at out_wav.
    """
    polly = polly or boto3.client("polly", region_name=settings.aws_region)
    voice_id, language = resolve_voice(polly, settings)
    log.info("voice-over: voice=%s language=%s engine=%s", voice_id, language, settings.polly_engine)

    clips_dir = workdir / "clips"
    clips_dir.mkdir(exist_ok=True)
    placed: list[tuple[float, Path]] = []
    sped_up = 0

    for i, (segment, slot) in enumerate(zip(segments, slots(segments, duration))):
        mp3 = synthesize(polly, segment.text, voice_id, language, settings.polly_engine, clips_dir / f"{i:04d}.mp3")
        fit = fit_to_slot(ffmpeg.duration(mp3), slot, settings.max_speedup)
        if fit.tempo > 1.0:
            sped_up += 1
        if fit.overrun > OVERRUN_WARN_SECONDS:
            log.warning(
                "segment %d at %.2fs overruns its %.2fs slot by %.2fs even at %.2fx: %r",
                i, segment.start, slot, fit.overrun, fit.tempo, segment.text[:60],
            )  # fmt: skip
        # Normalize every clip to the same WAV format, applying the speed-up.
        wav = clips_dir / f"{i:04d}.wav"
        tempo = ["-filter:a", f"atempo={fit.tempo:.4f}"] if fit.tempo > 1.0 else []
        ffmpeg.run(["-i", mp3, *tempo, "-ac", "1", "-ar", str(SAMPLE_RATE), "-c:a", "pcm_s16le", wav])
        placed.append((segment.start, wav))

    log.info("voice-over: %d clips, %d sped up", len(placed), sped_up)
    _mix(placed, duration, out_wav)
    return out_wav
