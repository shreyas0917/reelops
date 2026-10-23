"""Thin wrappers around the ffmpeg and ffprobe command-line tools."""

from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path

from . import PipelineError

log = logging.getLogger(__name__)


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


def probe(media: Path) -> dict:
    """Return ffprobe's format and stream info for a media file."""
    cmd = ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams"]
    proc = _exec([*cmd, str(media)])
    if proc.returncode != 0:
        raise _fail(f"ffprobe ({media.name})", proc)
    return json.loads(proc.stdout)


def duration(media: Path) -> float:
    """Duration of a media file in seconds."""
    try:
        return float(probe(media)["format"]["duration"])
    except (KeyError, ValueError):
        raise PipelineError(f"could not read the duration of {media.name}") from None


def has_stream(media: Path, codec_type: str) -> bool:
    """True if the file has at least one stream of codec_type ("audio"/"video")."""
    return any(s.get("codec_type") == codec_type for s in probe(media).get("streams", []))
