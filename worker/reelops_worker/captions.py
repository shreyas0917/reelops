"""Stage c: write an SRT subtitle file from transcript segments."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .transcribe import Segment


@dataclass(frozen=True)
class Caption:
    start: float
    end: float
    lines: tuple[str, ...]


def format_timestamp(seconds: float) -> str:
    """Seconds -> SRT timestamp "HH:MM:SS,mmm"."""
    # Round to whole milliseconds first so 59.9996 becomes 00:01:00,000,
    # not 00:00:59,1000.
    ms = max(0, round(seconds * 1000))
    hours, ms = divmod(ms, 3_600_000)
    minutes, ms = divmod(ms, 60_000)
    secs, ms = divmod(ms, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{ms:03d}"


def wrap_lines(text: str, max_chars: int) -> list[str]:
    """Greedy word wrap. Never splits a word; an over-long word gets its own line."""
    lines: list[str] = []
    current = ""
    for word in text.split():
        if not current:
            current = word
        elif len(current) + 1 + len(word) <= max_chars:
            current += " " + word
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def split_segment(segment: Segment, max_chars: int, max_lines: int) -> list[Caption]:
    """Split one segment into captions of at most max_lines lines each.

    Whisper gives timings per segment, not per caption, so the segment's time
    is shared between its captions in proportion to their character count.
    """
    lines = wrap_lines(segment.text, max_chars)
    if not lines:
        return []
    chunks = [lines[i : i + max_lines] for i in range(0, len(lines), max_lines)]
    weights = [sum(len(line) for line in chunk) for chunk in chunks]
    total = sum(weights)
    span = segment.end - segment.start

    captions = []
    start, done = segment.start, 0
    for chunk, weight in zip(chunks, weights, strict=True):
        done += weight
        end = segment.start + span * done / total
        captions.append(Caption(start, end, tuple(chunk)))
        start = end
    return captions


def write_srt(segments: list[Segment], out_srt: Path, max_chars: int, max_lines: int) -> Path:
    """Write segments as SRT to out_srt and return it.

    Long segments are split into several captions so no line exceeds
    max_chars and no caption exceeds max_lines.
    """
    captions = [c for seg in segments for c in split_segment(seg, max_chars, max_lines)]
    blocks = [
        f"{i}\n{format_timestamp(c.start)} --> {format_timestamp(c.end)}\n" + "\n".join(c.lines)
        for i, c in enumerate(captions, start=1)
    ]
    out_srt.write_text("\n\n".join(blocks) + "\n", encoding="utf-8")
    return out_srt
