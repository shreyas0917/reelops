"""Entry point.

  python -m reelops_worker <input.mp4> <output.mp4>   one video (CLI)
  python -m reelops_worker consume                    queue consumer
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from . import PipelineError
from .config import Settings

log = logging.getLogger("reelops_worker")


def _setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["consume"]:
        _setup_logging(verbose="-v" in argv[1:])
        from .consumer import main as consume

        try:
            return consume()
        except ValueError as exc:  # missing/invalid settings
            log.error("%s", exc)
            return 2

    parser = argparse.ArgumentParser(
        prog="python -m reelops_worker",
        description="Turn a screen recording into a captioned, AI-voiced video. "
        "Use 'python -m reelops_worker consume' to run the queue consumer instead.",
    )
    parser.add_argument("input", type=Path, help="input video (must have an audio track)")
    parser.add_argument("output", type=Path, help="output .mp4 path")
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    args = parser.parse_args(argv)

    _setup_logging(args.verbose)

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
