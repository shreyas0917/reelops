# shellcheck shell=bash
# The resource variables below are used by the drill scripts that source this.
# shellcheck disable=SC2034
# Shared helpers for the failure drills (source it; don't run it).
#
# Resources come from terraform/main outputs, so no names, ARNs or account IDs
# live in these files. Every job a drill creates is recorded in
# samples/output/chaos/jobs.txt; scripts/chaos/cleanup.sh deletes exactly those
# (raw upload, output video, job item) and nothing else.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

REGION="${AWS_REGION:-ap-south-1}"
export AWS_REGION="$REGION"
STATE="samples/output/chaos"
JOBS_FILE="$STATE/jobs.txt"
mkdir -p "$STATE"

tf_out() { terraform -chdir=terraform/main output -raw "$1"; }
tf_json() { terraform -chdir=terraform/main output -json "$1" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }
API=$(tf_out api_url)
QUEUE=$(tf_out jobs_queue_url)
DLQ=$(tf_out jobs_dlq_url)
TABLE=$(tf_out jobs_table_name)
BUCKET=$(tf_out media_bucket_name)
CLUSTER=$(tf_out ecs_cluster_name)
API_SERVICE=$(tf_json ecs_service_names api)
WORKER_SERVICE=$(tf_json ecs_service_names worker)
WORKER_LOGS=$(tf_json log_groups worker)

# ---- output --------------------------------------------------------------------

now() { date -u +%H:%M:%S; }
epoch() { date +%s; }
epoch_ms() { date +%s%3N; }
log() { echo "$(now) $*"; }
TEST_NAME="${TEST_NAME:-drill}"
pass() { echo "$(now) PASS $TEST_NAME: $*"; }
fail() { echo "$(now) FAIL $TEST_NAME: $*" >&2; exit 1; }
# Hide the account ID in anything we print (queue URLs, ARNs).
redact() { sed -E 's/[0-9]{12}/<account-id>/g'; }

# wait_until <timeout-s> <description> <command...>: poll every 5 s.
wait_until() {
  local timeout=$1 what=$2 start
  shift 2
  start=$(epoch)
  until "$@" >/dev/null; do
    [ $(($(epoch) - start)) -lt "$timeout" ] || fail "timed out after ${timeout}s waiting for: $what"
    sleep 5
  done
}

# ---- jobs ------------------------------------------------------------------------

# submit_job <file> [content-type]: create a job through the API, upload the
# file to its presigned URL, record the id, print it.
submit_job() {
  local file=$1 type=${2:-video/mp4} created id url
  created=$(curl -sf -m 15 -X POST "$API/jobs" -H 'Content-Type: application/json' \
    -d "$(python3 -I -c 'import json,os,sys; print(json.dumps({"filename": os.path.basename(sys.argv[1]), "content_type": sys.argv[2], "size": os.path.getsize(sys.argv[1])}))' "$file" "$type")")
  id=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$created")
  url=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["upload_url"])' <<<"$created")
  echo "$id $TEST_NAME $(date -u +%FT%TZ)" >>"$JOBS_FILE"
  curl -sf -m 300 -X PUT -H "Content-Type: $type" --upload-file "$file" "$url" >/dev/null
  echo "$id"
}

# job_field <id> <attribute>: one attribute of the job item ("" if absent).
job_field() {
  aws dynamodb get-item --table-name "$TABLE" --key "{\"job_id\": {\"S\": \"$1\"}}" --consistent-read \
    --output json | python3 -I -c '
import json, sys
item = json.load(sys.stdin).get("Item", {})
value = item.get(sys.argv[1], {})
print(next(iter(value.values()), "") if value else "")' "$2"
}
job_status() { job_field "$1" status; }
job_is() { [ "$(job_status "$1")" = "$2" ]; }

# job_summary <id>: the fields the drills report on.
job_summary() {
  local id=$1
  echo "status=$(job_field "$id" status) attempts=$(job_field "$id" attempts) error=\"$(job_field "$id" error)\""
}

# worker_log <id> <since-epoch-ms>: worker log lines about this job, oldest first,
# as "HH:MM:SS <task-id> <message>".
worker_log() {
  aws logs filter-log-events --log-group-name "$WORKER_LOGS" --start-time "$2" \
    --filter-pattern "\"$1\"" --output json | python3 -I -c '
import datetime, json, sys
for e in json.load(sys.stdin)["events"]:
    t = datetime.datetime.fromtimestamp(e["timestamp"] / 1000, datetime.UTC).strftime("%H:%M:%S")
    task = e["logStreamName"].rsplit("/", 1)[-1][:8]
    print(t, task, e["message"].rstrip())'
}

# job_stream <id> <since-epoch-ms>: full log stream name of the worker that
# claimed the job (from its "claimed by" event; listing streams by name only
# searches the first page).
job_stream() {
  # JSON + python, not --query: the CLI applies --query to each page of its
  # auto-pagination, so an empty last page prints an extra "None".
  aws logs filter-log-events --log-group-name "$WORKER_LOGS" --start-time "$2" \
    --filter-pattern "\"$1\" \"claimed by\"" --output json |
    python3 -I -c 'import json,sys; e=json.load(sys.stdin)["events"]; print(e[-1]["logStreamName"] if e else "")'
}

# output_count <id>: how many objects exist for this job's output.
output_count() {
  # Not list-objects-v2 --query KeyCount: the CLI's auto-pagination can print "None".
  aws s3 ls "s3://$BUCKET/output/$1" | grep -c "$1" || true
}

# ---- queue and services ------------------------------------------------------------

# A worker running elsewhere (e.g. docker compose on the dev box) consumes the
# same live queue: it would take the drill's jobs and nothing would reach ECS.
require_only_ecs_workers() {
  local local_workers
  local_workers=$(docker ps --filter "ancestor=reelops-worker:dev" --format '{{.Names}}' 2>/dev/null || true)
  [ -z "$local_workers" ] || fail "local worker container(s) running ($local_workers) consume the live queue; stop them first: docker compose stop worker"
}

queue_attr() {
  aws sqs get-queue-attributes --queue-url "$1" --attribute-names "$2" --query "Attributes.$2" --output text
}

running_tasks() {
  aws ecs list-tasks --cluster "$CLUSTER" --service-name "$1" --desired-status RUNNING --query 'taskArns' --output text
}
