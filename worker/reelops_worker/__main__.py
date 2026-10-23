"""CLI entry point: python -m reelops_worker <input.mp4> <output.mp4>"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from . import PipelineError
from .config import Settings

log = logging.getLogger("reelops_worker")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m reelops_worker",
        description="Turn a screen recording into a captioned, AI-voiced video.",
    )
    parser.add_argument("input", type=Path, help="input video (must have an audio track)")
    parser.add_argument("output", type=Path, help="output .mp4 path")
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )

    if not args.input.is_file():
        parser.error(f"input file not found: {args.input}")

    try:
        settings = Settings.from_env()
    except ValueError as exc:
        parser.error(str(exc))

    # Imported here so --help and argument errors don't pay for loading
    # faster-whisper and boto3.
    from .pipeline import run

    try:
        run(args.input, args.output, settings)
    except PipelineError as exc:
        log.error("%s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
