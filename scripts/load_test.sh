#!/usr/bin/env bash
# Load test of worker autoscaling: submit N jobs through the ALB, then sample
# queue depth and worker task counts every 15 s until all jobs are done and
# the worker service is back to 0. Writes samples/output/scaling.csv and
# samples/output/scaling_report.txt.
#
# Start from an idle stack (worker at 0) to measure scale-from-zero.
# Usage: scripts/load_test.sh [N] [video]       (default 8, samples/synthetic.mp4)
#        DRY_RUN=1 scripts/load_test.sh         (preflight + one sample, no jobs)
# Takes ~15-20 min (scale-in waits 10 idle minutes): run it in tmux or with
# nohup so a dropped terminal can't kill it.
set -euo pipefail

cd "$(dirname "$0")/.."
N="${1:-8}"
INPUT="${2:-samples/synthetic.mp4}"
INTERVAL=15
TIMEOUT_S="${TIMEOUT_S:-2700}" # scale-in alone takes ~10 min after the queue empties
OUT_DIR="samples/output"
# A dry run never overwrites a real run's results.
CSV="$OUT_DIR/scaling${DRY_RUN:+_dryrun}.csv"
REPORT="$OUT_DIR/scaling_report.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tf() { terraform -chdir=terraform/main output -raw "$1"; }
API="${API_URL:-$(tf api_url)}"
QUEUE_URL=$(tf jobs_queue_url)
CLUSTER=$(tf ecs_cluster_name)
SERVICE=$(terraform -chdir=terraform/main output -json ecs_service_names | python3 -I -c "import json,sys; print(json.load(sys.stdin)['worker'])")

now() { date +%s.%N; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }

queue_counts() { # -> "visible inflight"
  aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' --output text
}
service_counts() { # -> "desired running pending"
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text
}
record_tasks() { # remember every worker task we see (for exact start/stop times later)
  aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query 'taskArns[]' --output text \
    | tr '\t' '\n' | grep . >>"$WORK/tasks" || true
}
job_counts() { # -> "done failed"
  local done=0 failed=0 status
  while read -r id; do
    status=$(curl -sf -m 15 "$API/jobs/$id" | json "['status']" || echo unknown)
    case "$status" in done) done=$((done + 1)) ;; failed) failed=$((failed + 1)) ;; esac
  done <"$WORK/jobs"
  echo "$done $failed"
}
sample() { # append one CSV row; sets globals for the stop check
  read -r VISIBLE INFLIGHT <<<"$(queue_counts)"
  read -r DESIRED RUNNING PENDING <<<"$(service_counts)"
  read -r DONE FAILED <<<"$(job_counts)"
  record_tasks
  local elapsed
  elapsed=$(awk -v a="$T0" -v b="$(now)" 'BEGIN { printf "%.0f", b - a }')
  echo "$elapsed,$(date -u +%H:%M:%S),$VISIBLE,$INFLIGHT,$DESIRED,$RUNNING,$PENDING,$DONE,$FAILED" | tee -a "$CSV"
}

# ---- preflight ----------------------------------------------------------------
[ -f "$INPUT" ] || { echo "input not found: $INPUT (try scripts/make_sample.sh)" >&2; exit 1; }
curl -sf -m 15 "$API/healthz" >/dev/null || { echo "API not healthy at $API" >&2; exit 1; }
read -r DESIRED RUNNING PENDING <<<"$(service_counts)"
echo "API $API | worker service $SERVICE: desired=$DESIRED running=$RUNNING pending=$PENDING"
if [ "$DESIRED$RUNNING$PENDING" != "000" ]; then
  echo "WARNING: worker is not at 0; this run won't measure scale-from-zero" >&2
fi
mkdir -p "$OUT_DIR"
: >"$WORK/jobs"
: >"$WORK/tasks"
echo "elapsed_s,utc,visible,in_flight,desired,running,pending,jobs_done,jobs_failed" >"$CSV"

if [ -n "${DRY_RUN:-}" ]; then
  T0=$(now)
  sample
  echo "DRY_RUN: no jobs submitted; $CSV has one row"
  exit 0
fi

# ---- submit N jobs ------------------------------------------------------------
case "${INPUT##*.}" in
  mp4) CONTENT_TYPE=video/mp4 ;; mov) CONTENT_TYPE=video/quicktime ;; webm) CONTENT_TYPE=video/webm ;;
  *) echo "unsupported extension: $INPUT" >&2; exit 1 ;;
esac
SIZE=$(stat -c %s "$INPUT")
T0=""
for i in $(seq "$N"); do
  CREATE=$(curl -sf -m 15 -X POST "$API/jobs" -H 'content-type: application/json' \
    -d "{\"filename\": \"$(basename "$INPUT")\", \"content_type\": \"$CONTENT_TYPE\", \"size\": $SIZE}")
  curl -sf -m 300 -X PUT -H "Content-Type: $CONTENT_TYPE" --upload-file "$INPUT" -o /dev/null "$(json "['upload_url']" <<<"$CREATE")"
  json "['job_id']" <<<"$CREATE" >>"$WORK/jobs"
  [ -z "$T0" ] && T0=$(now) && T0_UTC=$(date -u +%FT%TZ) # first upload complete = first S3 event
done
echo "submitted $N jobs; first upload at $T0_UTC"
cp "$WORK/jobs" "$OUT_DIR/load_test_jobs.txt"

# ---- sample until done and back to 0 --------------------------------------------
while :; do
  sample
  if [ $((DONE + FAILED)) -eq "$N" ] && [ "$DESIRED$RUNNING$PENDING" = "000" ]; then break; fi
  if (($(awk -v a="$T0" -v b="$(now)" -v m="$TIMEOUT_S" 'BEGIN { print (b - a > m) }'))); then
    echo "timed out after ${TIMEOUT_S}s" >&2
    break
  fi
  sleep "$INTERVAL"
done

# ---- exact timings for the report -----------------------------------------------
while read -r id; do curl -sf -m 15 "$API/jobs/$id"; echo; done <"$WORK/jobs" >"$WORK/jobs.json"
sort -u "$WORK/tasks" | grep . >"$WORK/tasks.u" || true
: >"$WORK/tasks.json"
if [ -s "$WORK/tasks.u" ]; then
  # describe-tasks accepts up to 100 tasks; stopped tasks stay describable for ~1 hour.
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks $(head -100 "$WORK/tasks.u") \
    --query 'tasks[].{created:createdAt,started:startedAt,stopped:stoppedAt}' --output json >"$WORK/tasks.json"
fi
aws application-autoscaling describe-scaling-activities --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICE" --max-items 50 \
  --query 'ScalingActivities[].{start:StartTime,end:EndTime,desc:Description,status:StatusCode}' --output json >"$WORK/activities.json"

python3 -I - "$T0" "$N" "$WORK/jobs.json" "$WORK/tasks.json" "$WORK/activities.json" <<'PY' | tee "$REPORT"
import json, sys, datetime as dt

t0 = float(sys.argv[1]); n = int(sys.argv[2])
ts = lambda s: dt.datetime.fromisoformat(s).timestamp() if s else None
jobs = [json.loads(line) for line in open(sys.argv[3]) if line.strip()]
tasks = json.load(open(sys.argv[4])) if open(sys.argv[4]).read().strip() else []
acts = [a for a in json.load(open(sys.argv[5])) if ts(a["start"]) >= t0 - 60]
rel = lambda t: f"{t - t0:+7.1f}s" if t is not None else "     n/a"

done = [j for j in jobs if j["status"] == "done"]
print(f"jobs: {len(done)}/{n} done, {sum(j['status'] == 'failed' for j in jobs)} failed")

starts = sorted(ts(t["started"]) for t in tasks if t.get("started"))
if starts:
    print(f"cold start from 0 (first upload -> first worker task started): {starts[0] - t0:.1f}s")
    # exact concurrency: sweep over task start/stop events
    events = sorted([(ts(t["started"]), 1) for t in tasks if t.get("started")] +
                    [(ts(t["stopped"]), -1) for t in tasks if t.get("started") and t.get("stopped")])
    cur = peak = 0; peak_at = None
    for when, delta in events:
        cur += delta
        if cur > peak:
            peak, peak_at = cur, when
    print(f"peak running worker tasks: {peak}, reached at {rel(peak_at).strip()} after first upload")
    print(f"worker tasks used in total: {len(starts)}")

if done:
    last_done = max(j["updated_at"] for j in done)
    print(f"all jobs finished: {last_done - t0:.1f}s after first upload")
    to_zero = [ts(a["start"]) for a in acts if "to 0" in a["desc"] and ts(a["start"]) > last_done]
    if to_zero:
        print(f"queue empty (last job done) -> desired 0: {to_zero[0] - last_done:.1f}s")

print("\nscaling activities (Application Auto Scaling):")
for a in sorted(acts, key=lambda a: a["start"]):
    print(f"  {rel(ts(a['start']))}  {a['status']:<11} {a['desc']}")
PY
echo "wrote $CSV and $REPORT"
