#!/usr/bin/env bash
# Drill 3: inputs that can never succeed.
#
# A text file named .mp4, and a real video with no audio track. Both pass the
# API's checks (extension, size) and fail in the worker. Bad input is a
# permanent error (PipelineError): the job must be marked failed with a clear
# message after ONE attempt, and its message deleted, not retried into the DLQ.
#
# Needs: the live stack, aws CLI, ffmpeg.
# Usage: scripts/chaos/test3_poison_input.sh
TEST_NAME=test3-poison-input
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
require_only_ecs_workers

NOT_VIDEO="$STATE/not-a-video.mp4"
SILENT="$STATE/silent-video.mp4"
printf 'This is a text file pretending to be a video.\n%.0s' {1..200} >"$NOT_VIDEO"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 10 \
  -an -c:v libx264 -preset veryfast -pix_fmt yuv420p "$SILENT"
log "inputs: $(basename "$NOT_VIDEO") ($(stat -c %s "$NOT_VIDEO") bytes of text), $(basename "$SILENT") (10 s video, no audio)"

dlq_before=$(queue_attr "$DLQ" ApproximateNumberOfMessages)
since_ms=$(epoch_ms)
t_submit=$(epoch)
JOB_TEXT=$(submit_job "$NOT_VIDEO")
JOB_SILENT=$(submit_job "$SILENT")
log "submitted $JOB_TEXT (text) and $JOB_SILENT (no audio)"

wait_until 900 "text job failed" job_is "$JOB_TEXT" failed
wait_until 300 "silent job failed" job_is "$JOB_SILENT" failed
t_failed=$(epoch)
queue_empty() {
  [ "$(queue_attr "$QUEUE" ApproximateNumberOfMessages)" = 0 ] &&
    [ "$(queue_attr "$QUEUE" ApproximateNumberOfMessagesNotVisible)" = 0 ]
}
wait_until 120 "both messages deleted" queue_empty
sleep 20 # let any (unexpected) retry show up in the logs and the job items

for JOB in "$JOB_TEXT" "$JOB_SILENT"; do
  echo "---- $JOB: $(job_summary "$JOB")"
  worker_log "$JOB" "$since_ms"
done
echo "----"

check() { # check <job> <expected error fragment>
  local job=$1 want=$2 claims
  job_is "$job" failed || fail "$job: $(job_summary "$job"), expected failed"
  [ "$(job_field "$job" attempts)" = 1 ] || fail "$job: attempts=$(job_field "$job" attempts), expected 1 (not retried)"
  job_field "$job" error | grep -qi "$want" || fail "$job: error doesn't mention \"$want\""
  claims=$(worker_log "$job" "$since_ms" | grep -c "claimed by" || true)
  [ "$claims" = 1 ] || fail "$job: claimed $claims times, expected 1"
  [ "$(output_count "$job")" = 0 ] || fail "$job: has an output object"
}
check "$JOB_TEXT" "isn't an MP4, MOV or WebM video"
check "$JOB_SILENT" "no audio stream"
dlq_after=$(queue_attr "$DLQ" ApproximateNumberOfMessages)
log "DLQ before=$dlq_before after=$dlq_after; queue empty"
[ "$dlq_after" = "$dlq_before" ] || fail "DLQ changed ($dlq_before -> $dlq_after)"
pass "both poison inputs failed once with a clear error within $((t_failed - t_submit))s; attempts=1, messages deleted, nothing in the DLQ, no output"
