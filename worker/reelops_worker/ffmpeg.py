"""Thin wrappers around the ffmpeg and ffprobe command-line tools."""

from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path

from . import PipelineError

log = logging.getLogger(__name__)

# Demuxers allowed to open user uploads. ffmpeg picks a demuxer from the file's
# contents, not its name, so without this a crafted "video.mp4" could reach
# e.g. the DASH demuxer and its XML parser (libxml2). Only our own
# intermediate files (Polly mp3, wav, the rendered output) skip it.
UPLOAD_FORMATS = "mov,mp4,m4a,3gp,3g2,mj2,matroska,webm"


def upload_input(path: Path) -> list[str | Path]:
    """ffmpeg input arguments for an untrusted upload."""
    return ["-format_whitelist", UPLOAD_FORMATS, "-i", path]


def _exec(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    log.debug("exec: %s", " ".join(cmd))
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        raise PipelineError(f"{cmd[0]} not found on PATH; is ffmpeg installed?") from None


def _fail(tool: str, proc: subprocess.CompletedProcess[str]) -> PipelineError:
    tail = "\n".join(proc.stderr.strip().splitlines()[-5:])
    return PipelineError(f"{tool} failed (exit {proc.returncode}): {tail}")


def run(args: list[str | Path], cwd: Path | None = None) -> None:
    """Run ffmpeg with args; overwrite outputs, no stdin, errors only."""
    cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
    cmd += [str(a) for a in args]
    proc = _exec(cmd, cwd)
    if proc.returncode != 0:
        raise _fail("ffmpeg", proc)


def probe(media: Path, *, untrusted: bool = False) -> dict:
    """Return ffprobe's format and stream info. untrusted=True for uploads."""
    cmd = ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams"]
    if untrusted:
        cmd += ["-format_whitelist", UPLOAD_FORMATS]
    proc = _exec([*cmd, str(media)])
    if proc.returncode != 0:
        if untrusted and "not on whitelist" in proc.stderr:
            raise PipelineError(
                f"{media.name} isn't an MP4, MOV or WebM video. Export it as MP4 and upload it again."
            )
        raise _fail(f"ffprobe ({media.name})", proc)
    return json.loads(proc.stdout)


def duration(media: Path, *, untrusted: bool = False) -> float:
    """Duration of a media file in seconds."""
    try:
        return float(probe(media, untrusted=untrusted)["format"]["duration"])
    except (KeyError, ValueError):
        raise PipelineError(f"could not read the duration of {media.name}") from None


def has_stream(media: Path, codec_type: str, *, untrusted: bool = False) -> bool:
    """True if the file has at least one stream of codec_type ("audio"/"video")."""
    return any(s.get("codec_type") == codec_type for s in probe(media, untrusted=untrusted).get("streams", []))
