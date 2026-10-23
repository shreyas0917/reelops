"""Stage e: burn captions in, swap in the voice-over, encode H.264 + AAC."""

from __future__ import annotations

from pathlib import Path

from . import ffmpeg

# libass style for burned-in captions. FontSize is relative to a 288px-tall
# canvas that libass scales to the video, so it reads the same at any size.
# Colours are &HAABBGGRR: white text, black outline. Alignment=2 = bottom centre.
CAPTION_STYLE = ",".join(
    [
        "FontName=DejaVu Sans",
        "FontSize=18",
        "PrimaryColour=&H00FFFFFF",
        "OutlineColour=&H00000000",
        "BorderStyle=1",
        "Outline=2",
        "Shadow=0",
        "Alignment=2",
        "MarginV=20",
    ]
)


def render(video: Path, srt: Path, voiceover: Path, out_mp4: Path) -> Path:
    """Write the final video to out_mp4 and return it.

    ffmpeg runs inside the SRT's directory so the subtitles filter gets a bare
    filename; full paths in filter arguments need fragile escaping.
    """
    filters = ",".join(
        [
            # yuv420p H.264 needs even dimensions; screen recordings often aren't.
            "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            f"subtitles={srt.name}:force_style='{CAPTION_STYLE}'",
        ]
    )
    ffmpeg.run(
        [
            *ffmpeg.upload_input(video.resolve()),
            "-i", voiceover.resolve(),
            "-map", "0:v:0", "-map", "1:a:0",
            "-vf", filters,
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            out_mp4.resolve(),
        ],
        cwd=srt.parent,
    )  # fmt: skip
    return out_mp4
