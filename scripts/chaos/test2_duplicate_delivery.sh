#!/usr/bin/env bash
# Drill 2: the same S3 upload event is delivered again after the job is done.
#
# S3 notifications and SQS are both at-least-once. A duplicate of a finished
# job's event must be skipped: the worker's claim is conditional, so it sees
# status=done, logs "duplicate skipped (already done)" and deletes the
# message. The job item and the output object must not change at all.
#
# Needs: the live stack, aws CLI, samples/output/ui-fixture/recording.mp4.
# Usage: scripts/chaos/test2_duplicate_delivery.sh
TEST_NAME=test2-duplicate-delivery
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

INPUT="samples/output/ui-fixture/recording.mp4"
[ -f "$INPUT" ] || fail "missing $INPUT; run scripts/make_ui_fixture.sh first"
require_only_ecs_workers

JOB=$(submit_job "$INPUT")
log "submitted job $JOB (31 s recording)"
wait_until 900 "job done" job_is "$JOB" "done"
log "done: $(job_summary "$JOB")"

item_json() {
  aws dynamodb get-item --table-name "$TABLE" --key "{\"job_id\": {\"S\": \"$JOB\"}}" --consistent-read --output json
}
output_modified() {
  aws s3api head-object --bucket "$BUCKET" --key "output/$JOB.mp4" --query LastModified --output text
}
before=$(item_json)
before_output=$(output_modified)

# The event S3 sent for this upload, rebuilt from the object itself.
KEY=$(job_field "$JOB" s3_key)
read -r SIZE ETAG < <(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query '[ContentLength,ETag]' --output text)
BODY=$(python3 -I -c '
import json, sys, urllib.parse
bucket, key, size, etag = sys.argv[1:5]
obj = {"key": urllib.parse.quote_plus(key, safe="/"), "size": int(size), "eTag": etag.strip(chr(34))}
print(json.dumps({"Records": [{"eventSource": "aws:s3", "eventName": "ObjectCreated:Put",
                               "s3": {"bucket": {"name": bucket}, "object": obj}}]}))' "$BUCKET" "$KEY" "$SIZE" "$ETAG")
since_ms=$(epoch_ms)
t_send=$(epoch)
aws sqs send-message --queue-url "$QUEUE" --message-body "$BODY" >/dev/null
log "re-sent the S3 event for $KEY"

skipped() { worker_log "$JOB" "$since_ms" | grep -q "duplicate skipped"; }
wait_until 600 "worker logs the duplicate as skipped" skipped
t_skip=$(epoch)
queue_empty() {
  [ "$(queue_attr "$QUEUE" ApproximateNumberOfMessages)" = 0 ] &&
    [ "$(queue_attr "$QUEUE" ApproximateNumberOfMessagesNotVisible)" = 0 ]
}
wait_until 120 "duplicate message deleted" queue_empty

echo "---- worker log since the re-send (time, task, message)"
worker_log "$JOB" "$since_ms"
echo "----"

after=$(item_json)
after_output=$(output_modified)
same_item=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]) == json.loads(sys.argv[2]))' "$before" "$after")
log "item unchanged: $same_item ($(job_summary "$JOB") updated_at=$(job_field "$JOB" updated_at))"
log "output LastModified before=$before_output after=$after_output; outputs=$(output_count "$JOB")"

[ "$same_item" = True ] || fail "job item changed"
[ "$before_output" = "$after_output" ] || fail "output object was rewritten"
[ "$(output_count "$JOB")" = 1 ] || fail "expected exactly 1 output object"
pass "duplicate event skipped $((t_skip - t_send))s after the re-send; message deleted; job item and output unchanged"
