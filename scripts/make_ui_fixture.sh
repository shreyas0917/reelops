#!/usr/bin/env bash
# Build the "finished video" for the Playwright screenshots (git-ignored):
#   1. record a scripted walkthrough of an invented app (scripts/ui-fixture/
#      fernhill.html) at 1280x720 with Playwright, timed by walkthrough.json;
#   2. narrate each step with Polly and mux it: a realistic screen recording;
#   3. run it through the real ReelOps pipeline (Whisper, captions, Polly
#      re-voice, render) and keep the output and its real caption segments;
#   4. encode both to VP9/Opus (Playwright's Chromium has no H.264).
# Writes frontend/e2e/fixtures/{done.webm,original.webm,fixture.json}.
#
# Needs: docker, the Playwright image, the worker image
# (docker build -t reelops-worker:test --target test worker), frontend
# node_modules (npm ci), aws CLI (Polly via the instance role), ffmpeg.
# Usage: scripts/make_ui_fixture.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${AWS_REGION:-ap-south-1}"
PLAYWRIGHT="mcr.microsoft.com/playwright:v1.64.0-noble"
WORKER="reelops-worker:test"
SRC="scripts/ui-fixture"
WORK="samples/output/ui-fixture"
OUT="frontend/e2e/fixtures"
rm -rf "$WORK" && mkdir -p "$WORK" "$OUT"

# Steps as "at<TAB>sentence" lines, plus the voice and total length.
steps() { python3 -I -c 'import json,sys; [print(s["at"], s["say"], sep="\t") for s in json.load(open(sys.argv[1]))["steps"]]' "$SRC/walkthrough.json"; }
field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$SRC/walkthrough.json" "$1"; }
VOICE=$(field voice)
TOTAL=$(field durationS)
seconds() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

echo "1/4 recording the walkthrough (${TOTAL}s)..."
docker run --rm --name reelops-ui-record --ipc=host --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/frontend:/frontend:ro" -v "$PWD/$SRC:/fx:ro" -v "$PWD/$WORK:/work" \
  "$PLAYWRIGHT" node /fx/record.mjs /frontend /work
LEAD_IN=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["leadInS"])' "$WORK/timing.json")

echo "2/4 narrating with Polly ($VOICE) and muxing..."
inputs=() filters="" labels="" i=0
mapfile -t lines < <(steps)
# A process substitution's failure doesn't trip set -e: check the result instead.
[ "${#lines[@]}" -gt 0 ] || { echo "no steps read from $SRC/walkthrough.json" >&2; exit 1; }
for line in "${lines[@]}"; do
  at=${line%%$'\t'*} text=${line#*$'\t'}
  mp3="$WORK/say-$i.mp3"
  aws polly synthesize-speech --region "$REGION" --engine neural --voice-id "$VOICE" \
    --text "$text" --output-format mp3 --sample-rate 24000 "$mp3" >/dev/null
  # Each sentence must finish before the next step starts.
  next=$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); i=int(sys.argv[2]); print(s["steps"][i+1]["at"] if i+1 < len(s["steps"]) else s["durationS"])' "$SRC/walkthrough.json" "$i")
  awk -v a="$at" -v d="$(seconds "$mp3")" -v n="$next" -v t="$text" \
    'BEGIN { if (a + d > n - 0.2) { printf "sentence too long for its slot (%.1fs > %.1fs): %s\n", d, n - a - 0.2, t; exit 1 } }'
  ms=$(awk -v a="$at" 'BEGIN { printf "%d", a * 1000 }')
  inputs+=(-i "$mp3")
  filters+="[$((i + 1)):a]adelay=${ms}:all=1[a$i];"
  labels+="[a$i]"
  i=$((i + 1))
done
ffmpeg -hide_banner -loglevel error -y -ss "$LEAD_IN" -i "$WORK/screen.webm" "${inputs[@]}" \
  -filter_complex "${filters}${labels}amix=inputs=$i:normalize=0,apad[aout]" \
  -map 0:v -map "[aout]" -t "$TOTAL" -r 30 \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart \
  "$WORK/recording.mp4"

echo "3/4 running the ReelOps pipeline (Whisper, captions, Polly re-voice, render)..."
# REELOPS_WHISPER_HOTWORDS: without the hint Whisper writes "Reel Ops" or "real
# ops". Keep it to the one word: a longer hint also changed how Whisper split
# sentences into segments (captions broke mid-sentence).
docker run --rm --name reelops-ui-pipeline --user "$(id -u):$(id -g)" -e AWS_REGION="$REGION" \
  -e REELOPS_WHISPER_HOTWORDS=ReelOps \
  -v "$PWD/$WORK:/work" -v "$PWD/$SRC:/fx:ro" -w /app -e PYTHONPATH=/app \
  --entrypoint python "$WORKER" /fx/run_pipeline.py /work/recording.mp4 /work

echo "4/4 encoding the fixtures (VP9/Opus)..."
# Full 1280x720: downscaling first made the burned-in captions' word gaps vanish.
vp9() { ffmpeg -hide_banner -loglevel error -y -i "$1" -vf fps=24 \
  -c:v libvpx-vp9 -b:v 0 -crf 34 -row-mt 1 -deadline good -cpu-used 4 -c:a libopus -b:a 48k "$2"; }
vp9 "$WORK/output.mp4" "$OUT/done.webm"
vp9 "$WORK/recording.mp4" "$OUT/original.webm"
cp "$WORK/fixture.json" "$OUT/fixture.json"
ls -la "$OUT"
