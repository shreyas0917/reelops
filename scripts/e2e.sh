#!/usr/bin/env bash
# End-to-end test of the local stack against real AWS:
#   POST /jobs -> upload with curl to the presigned URL -> poll until done ->
#   download -> re-send the same S3 event by hand and check it's skipped.
#
# Needs: docker compose stack running (docker compose up -d --build --wait),
# .env from scripts/env_from_tf.sh, aws CLI, curl, python3, ffprobe.
# Waits up to 60 s for /healthz, so it also works right after `up` without --wait.
# Usage: scripts/e2e.sh [video]          (default samples/synthetic.mp4)
#        API_URL=http://<alb-dns> scripts/e2e.sh   (against ECS; worker logs
#        are then read from CloudWatch instead of docker compose)
set -euo pipefail

cd "$(dirname "$0")/.."
API="${API_URL:-${API:-http://localhost:8000}}"
WORKER_LOG_GROUP="${WORKER_LOG_GROUP:-/reelops/dev/worker}"
case "$API" in
  http://localhost* | http://127.0.0.1*) WORKER_LOGS=compose ;;
  *) WORKER_LOGS=cloudwatch ;;
esac

# Print the first worker log line containing $1 logged since epoch-ms $2.
worker_log() {
  if [ "$WORKER_LOGS" = compose ]; then
    docker compose logs --since "$(date -u -d "@$(($2 / 1000))" +%Y-%m-%dT%H:%M:%SZ)" worker 2>/dev/null \
      | grep -F "$1" | head -1 | sed 's/^[^|]*| //' || true
  else
    aws logs filter-log-events --log-group-name "$WORKER_LOG_GROUP" --start-time "$2" \
      --filter-pattern "\"$1\"" --query 'events[0].message' --output text 2>/dev/null | grep -v '^None$' || true
  fi
}
INPUT="${1:-samples/synthetic.mp4}"
OUT_DIR="samples/output"
TIMEOUT_S=300

now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print(d$1 if d$1 is not None else '')"; }

# ---- preflight ----------------------------------------------------------------
[ -f "$INPUT" ] || { echo "input not found: $INPUT (try scripts/make_sample.sh)" >&2; exit 1; }
[ -f .env ] || { echo ".env missing: run scripts/env_from_tf.sh" >&2; exit 1; }
for _ in $(seq 30); do
  curl -sf "$API/healthz" >/dev/null && break
  sleep 2
done
curl -sf "$API/healthz" >/dev/null || { echo "API not healthy at $API after 60s: docker compose up -d --build --wait" >&2; exit 1; }
set -a; . ./.env; set +a

case "${INPUT##*.}" in
  mp4) CONTENT_TYPE=video/mp4 ;;
  mov) CONTENT_TYPE=video/quicktime ;;
  webm) CONTENT_TYPE=video/webm ;;
  *) echo "unsupported extension: $INPUT" >&2; exit 1 ;;
esac
SIZE=$(stat -c %s "$INPUT")
T0=$(now)

# ---- 1. create job ------------------------------------------------------------
t=$(now)
CREATE=$(curl -sf -X POST "$API/jobs" -H 'content-type: application/json' \
  -d "{\"filename\": \"$(basename "$INPUT")\", \"content_type\": \"$CONTENT_TYPE\", \"size\": $SIZE}")
JOB_ID=$(json "['job_id']" <<<"$CREATE")
UPLOAD_URL=$(json "['upload_url']" <<<"$CREATE")
T_CREATE=$(since "$t")
echo "1. created job $JOB_ID (${T_CREATE}s)"

# ---- 2. upload straight to S3 ---------------------------------------------------
t=$(now)
HEADERS=$(curl -sf -X PUT -H "Content-Type: $CONTENT_TYPE" --upload-file "$INPUT" -D - -o /dev/null "$UPLOAD_URL")
ETAG=$(grep -i '^etag:' <<<"$HEADERS" | tr -d '\r"' | awk '{print $2}')
T_UPLOAD=$(since "$t")
echo "2. uploaded $(basename "$INPUT") ($((SIZE / 1024)) KiB) to S3 in ${T_UPLOAD}s, ETag $ETAG"

# ---- 3. poll until done/failed --------------------------------------------------
t=$(now)
last=""
while :; do
  JOB=$(curl -sf "$API/jobs/$JOB_ID")
  status=$(json "['status']" <<<"$JOB")
  if [ "$status" != "$last" ]; then
    echo "3. +$(since "$t")s status: $status"
    last=$status
  fi
  case "$status" in done | failed) break ;; esac
  if (( $(awk -v e="$(since "$t")" -v m="$TIMEOUT_S" 'BEGIN { print (e > m) }') )); then
    echo "timed out after ${TIMEOUT_S}s (status $status)" >&2; exit 1
  fi
  sleep 2
done
T_PROCESS=$(since "$t")
if [ "$status" = failed ]; then
  echo "job failed: $(json "['error']" <<<"$JOB")" >&2; exit 1
fi
ATTEMPTS=$(json "['attempts']" <<<"$JOB")

# ---- 4. download ------------------------------------------------------------------
t=$(now)
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$JOB_ID.mp4"
curl -sf -o "$OUT" "$(json "['download_url']" <<<"$JOB")"
T_DOWNLOAD=$(since "$t")
echo "4. downloaded $OUT ($(($(stat -c %s "$OUT") / 1024)) KiB, $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s) in ${T_DOWNLOAD}s"
T_TOTAL=$(since "$T0")

# ---- 5. duplicate event -------------------------------------------------------------
# Re-send the event S3 would send for this upload (at-least-once delivery means
# real duplicates happen). The worker must skip it and leave the job done.
KEY="raw/$JOB_ID/input.${INPUT##*.}"
EVENT=$(python3 -I -c '
import json, sys, urllib.parse
bucket, key, size, etag = sys.argv[1:]
print(json.dumps({"Records": [{"eventSource": "aws:s3", "eventName": "ObjectCreated:Put",
  "s3": {"bucket": {"name": bucket},
         "object": {"key": urllib.parse.quote_plus(key, safe="/"), "size": int(size), "eTag": etag}}}]}))
' "$REELOPS_MEDIA_BUCKET" "$KEY" "$SIZE" "$ETAG")
since_ms=$(($(date +%s) * 1000 - 5000))
t=$(now)
aws sqs send-message --queue-url "$REELOPS_JOBS_QUEUE_URL" --message-body "$EVENT" --output text --query MessageId >/dev/null
echo "5. re-sent the S3 event for $KEY by hand (watching $WORKER_LOGS worker logs)"
line=""
for _ in $(seq 60); do # CloudWatch delivery lags a few seconds
  line=$(worker_log "job $JOB_ID: duplicate skipped" "$since_ms")
  [ -n "$line" ] && break
  sleep 1
done
[ -n "$line" ] || { echo "worker did not log 'duplicate skipped' within 60s" >&2; exit 1; }
echo "   worker log: $line"
JOB=$(curl -sf "$API/jobs/$JOB_ID")
echo "   job after duplicate: status=$(json "['status']" <<<"$JOB") attempts=$(json "['attempts']" <<<"$JOB") (before: done, $ATTEMPTS)"
[ "$(json "['status']" <<<"$JOB")" = done ] && [ "$(json "['attempts']" <<<"$JOB")" = "$ATTEMPTS" ] \
  || { echo "duplicate changed the job!" >&2; exit 1; }
T_DUP=$(since "$t")

# ---- timings ------------------------------------------------------------------------
cat <<EOF

timings
  create job          ${T_CREATE}s
  upload to S3        ${T_UPLOAD}s
  queue + processing  ${T_PROCESS}s   (upload done -> status done, polled every 2 s)
  download            ${T_DOWNLOAD}s
  total               ${T_TOTAL}s
  duplicate handled   ${T_DUP}s
EOF
