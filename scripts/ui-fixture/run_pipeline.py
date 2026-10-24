"""Run the real ReelOps pipeline on the walkthrough recording and save what
the job record would hold, for the UI screenshots.

Run by scripts/make_ui_fixture.sh inside the worker image (Whisper model baked
in; Polly via the instance role):  python run_pipeline.py <input.mp4> <work dir>
Writes <work>/output.mp4 and <work>/fixture.json.
"""

import json
import sys
from pathlib import Path

from reelops_worker import ffmpeg
from reelops_worker.config import Settings
from reelops_worker.pipeline import run

src, work = Path(sys.argv[1]), Path(sys.argv[2])
result = run(src, work / "output.mp4", Settings.from_env())
fixture = {
    "durationS": round(ffmpeg.duration(result.output), 3),
    "voice": result.voice,
    "segments": [
        {"start": round(c.start, 3), "end": round(c.end, 3), "text": " ".join(c.lines)} for c in result.captions
    ],
}
(work / "fixture.json").write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")
for s in fixture["segments"]:
    print(f"{s['start']:6.2f}-{s['end']:6.2f}  {s['text']}")

# The narration names the product; a misspelt brand in the README screenshot
# would look careless. make_ui_fixture.sh sets REELOPS_WHISPER_HOTWORDS for this.
if not any("ReelOps" in s["text"] for s in fixture["segments"]):
    sys.exit('Whisper did not write "ReelOps" in any caption; is REELOPS_WHISPER_HOTWORDS=ReelOps set?')
