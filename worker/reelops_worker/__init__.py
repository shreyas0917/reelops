"""ReelOps worker: screen recording in, captioned AI-voiced video out."""

__version__ = "0.1.0"


class PipelineError(Exception):
    """An expected, user-facing failure (bad input, missing audio, AWS error).

    The CLI prints these as a one-line message; anything else is a bug and
    keeps its traceback.
    """
