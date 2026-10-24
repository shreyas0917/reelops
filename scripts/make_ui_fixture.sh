#!/usr/bin/env bash
# Create frontend/e2e/fixtures/done.webm (git-ignored), the "finished video"
# in the Playwright screenshots: a ReelOps output for samples/synthetic.mp4,
# re-encoded to VP9/Opus because Playwright's Chromium has no H.264.
# The SEGMENTS in frontend/e2e/states.spec.ts are that input's captions, so
# use an output of synthetic.mp4 (e.g. from scripts/e2e.sh), not another video.
#
# Needs: the worker image (docker build -t reelops-worker:test --target test worker).
# Usage: scripts/make_ui_fixture.sh samples/output/<job-id>.mp4
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:?usage: scripts/make_ui_fixture.sh samples/output/<job-id>.mp4}"
OUT_DIR="frontend/e2e/fixtures"
mkdir -p "$OUT_DIR"

docker run --rm --network none --name reelops-ui-fixture \
  -v "$PWD/$(dirname "$SRC"):/in:ro" -v "$PWD/$OUT_DIR:/out" --user "$(id -u):$(id -g)" \
  --entrypoint ffmpeg reelops-worker:test -v error -y -i "/in/$(basename "$SRC")" \
  -vf scale=960:-2,fps=24 -c:v libvpx-vp9 -b:v 0 -crf 46 -row-mt 1 -deadline good -cpu-used 4 \
  -c:a libopus -b:a 32k /out/done.webm
ls -la "$OUT_DIR/done.webm"
