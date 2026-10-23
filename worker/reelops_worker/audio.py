"""Stage a: extract a 16 kHz mono WAV from the input video with ffmpeg."""

from __future__ import annotations

from pathlib import Path

from . import PipelineError, ffmpeg


class NoAudioStreamError(PipelineError):
    """The input video has no audio track to transcribe."""


def extract_audio(video: Path, out_wav: Path) -> Path:
    """Write the video's audio as 16 kHz mono PCM WAV to out_wav and return it.

    Raises NoAudioStreamError if the video has no audio stream.
    """
    if not ffmpeg.has_stream(video, "audio", untrusted=True):
        raise NoAudioStreamError(
            f"{video.name} has no audio stream. ReelOps needs a narrated recording "
            "to transcribe; record with your microphone on."
        )
    # 16 kHz mono 16-bit PCM is what Whisper expects.
    ffmpeg.run([*ffmpeg.upload_input(video), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", out_wav])
    return out_wav
