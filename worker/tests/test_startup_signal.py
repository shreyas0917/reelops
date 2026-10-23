import os
import signal
import subprocess
import sys
import time

# Fake settings: if the stop is honoured, nothing ever reaches AWS.
FAKE_ENV = {
    "REELOPS_JOBS_QUEUE_URL": "https://sqs.ap-south-1.amazonaws.com/000000000000/jobs",
    "REELOPS_MEDIA_BUCKET": "reelops-media-test",
    "REELOPS_JOBS_TABLE": "jobs",
}


def test_sigterm_during_startup_exits_cleanly():
    """Regression: SIGTERM sent while the consumer is still importing/loading
    used to be lost (as PID 1 with no handler), ending in SIGKILL after the
    grace period. It must now be caught early and end in a clean exit.
    """
    proc = subprocess.Popen(
        [sys.executable, "-m", "reelops_worker", "consume"],
        env={**os.environ, **FAKE_ENV},
        stderr=subprocess.PIPE,
        text=True,
    )
    lines = []
    deadline = time.monotonic() + 30
    for line in proc.stderr:  # wait until the early handler is installed
        lines.append(line)
        if "consumer starting" in line or time.monotonic() > deadline:
            break
    proc.send_signal(signal.SIGTERM)  # lands during the heavy imports / model load
    _, rest = proc.communicate(timeout=30)  # (stdout, stderr); only stderr is piped
    output = "".join(lines) + rest

    assert proc.returncode == 0, output  # not -15 (killed by the default action)
    assert "stop requested during startup" in output
    assert "polling" not in output
