#!/usr/bin/env bash
# Create samples/synthetic.mp4: a ~30 s Polly-narrated test-pattern video.
# Videos are git-ignored, so this script is how everyone gets the same input.
#
# Needs: aws CLI (credentials from the instance role), ffmpeg, ffprobe.
# Usage: scripts/make_sample.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${AWS_REGION:-ap-south-1}"
VOICE="Matthew" # en-US; the worker re-voices it (Kajal by default), so the change is audible
OUT="samples/synthetic.mp4"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Pauses between sentences give Whisper distinct segments and give each
# voice-over clip room in its slot, like real narration.
cat >"$tmp/narration.ssml" <<'EOF'
<speak>
Welcome to ReelOps. <break time="1s"/>
In this demo, we upload a screen recording and let the pipeline do the rest. <break time="1s"/>
First, the worker extracts the audio and transcribes it with Whisper. <break time="1s"/>
Next, it writes captions and asks Amazon Polly for a fresh voice-over, one sentence at a time. <break time="1s"/>
Finally, ffmpeg burns in the captions and swaps in the new audio. <break time="1s"/>
The result is a polished demo video, ready to share.
</speak>
EOF

echo "Synthesizing narration with Polly ($VOICE, $REGION)..."
aws polly synthesize-speech --region "$REGION" \
  --engine neural --voice-id "$VOICE" \
  --text-type ssml --text "file://$tmp/narration.ssml" \
  --output-format mp3 --sample-rate 24000 \
  "$tmp/narration.mp3" >/dev/null

# Video runs 1.5 s past the narration so the last sentence isn't cut off.
narration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/narration.mp3")
total=$(awk -v d="$narration" 'BEGIN { printf "%.2f", d + 1.5 }')

echo "Rendering ${total}s test video..."
mkdir -p samples
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -i "$tmp/narration.mp3" \
  -filter:a apad -t "$total" \
  -c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart \
  "$OUT"

echo "Wrote $OUT ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s)"
