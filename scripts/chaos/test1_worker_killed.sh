#!/usr/bin/env bash
# Drill 1: stop the worker task that is processing a job.
#
# `aws ecs stop-task` sends SIGTERM (then SIGKILL after stopTimeout = 30 s).
# The worker's designed response: stop polling, give the job a 20 s grace
# period, then hand it back (job -> pending, message visible again at once).
# A replacement worker must claim it (attempts 1 -> 2) and finish it, with one
# output object. The worker processes ~7.6x faster than real time on Fargate
# (124 s of input in 16 s), so the input is ~8 min: about 70 s of processing,
# enough that the job can't finish inside the 20 s grace period.
#
# Needs: the live stack (enable_compute = true), aws CLI, ffmpeg, and
# samples/output/ui-fixture/recording.mp4 (scripts/make_ui_fixture.sh).
# Usage: scripts/chaos/test1_worker_killed.sh
TEST_NAME=test1-worker-killed
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

SRC="samples/output/ui-fixture/recording.mp4"
INPUT="$STATE/walkthrough-8min.mp4"
[ -f "$SRC" ] || fail "missing $SRC; run scripts/make_ui_fixture.sh first"
if [ ! -f "$INPUT" ]; then
  # The narrated walkthrough 16 times over: ~8 min of real speech.
  ffmpeg -hide_banner -loglevel error -y -stream_loop 15 -i "$SRC" -c copy "$INPUT"
fi
log "input $(basename "$INPUT"): $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" | cut -d. -f1)s"
require_only_ecs_workers
log "worker tasks running: $(running_tasks "$WORKER_SERVICE" | wc -w)"

t_submit=$(epoch); since_ms=$(epoch_ms)
JOB=$(submit_job "$INPUT")
log "submitted job $JOB"

wait_until 900 "job claimed (cold start included)" job_is "$JOB" processing
t_claim=$(epoch)
log "claimed after $((t_claim - t_submit))s: $(job_summary "$JOB")"

# Which task holds it: the log stream of its "claimed" line.
find_owner() { worker_log "$JOB" "$since_ms" | grep -m1 "claimed by" | cut -d' ' -f2; }
wait_until 120 "claim log line" find_owner
OWNER=$(find_owner)
TASK_ARN=$(running_tasks "$WORKER_SERVICE" | tr '\t' '\n' | grep "/$OWNER") || fail "no running task matches $OWNER"
log "owner task ${OWNER}"

sleep 5 # into the job, with ~60 s of work still ahead
job_is "$JOB" processing || fail "job left processing before the stop: $(job_summary "$JOB")"
t_stop=$(epoch)
aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" --reason "chaos drill: $TEST_NAME" >/dev/null
log "stop-task sent to ${OWNER} (SIGTERM)"

wait_until 90 "job handed back (pending)" job_is "$JOB" pending
t_back=$(epoch)
log "handed back after $((t_back - t_stop))s: $(job_summary "$JOB")"

reclaimed() { job_is "$JOB" processing && [ "$(job_field "$JOB" attempts)" = 2 ]; }
wait_until 900 "re-claimed by a replacement worker (attempts 2)" reclaimed
t_reclaim=$(epoch)
log "re-claimed after $((t_reclaim - t_stop))s from the stop: $(job_summary "$JOB")"

wait_until 900 "job done" job_is "$JOB" "done"
t_done=$(epoch)
log "done after $((t_done - t_stop))s from the stop: $(job_summary "$JOB")"

queue_empty() {
  [ "$(queue_attr "$QUEUE" ApproximateNumberOfMessages)" = 0 ] &&
    [ "$(queue_attr "$QUEUE" ApproximateNumberOfMessagesNotVisible)" = 0 ]
}
wait_until 120 "queue empty (message deleted)" queue_empty

echo "---- worker log for $JOB (time, task, message)"
worker_log "$JOB" "$since_ms"
echo "----"

attempts=$(job_field "$JOB" attempts)
outputs=$(output_count "$JOB")
new_owner=$(worker_log "$JOB" "$since_ms" | grep "claimed by" | tail -1 | cut -d' ' -f2)
log "attempts=$attempts outputs=$outputs first-owner=$OWNER final-owner=$new_owner"
log "timings: claim=$((t_claim - t_submit))s stop->pending=$((t_back - t_stop))s stop->reclaim=$((t_reclaim - t_stop))s stop->done=$((t_done - t_stop))s total=$((t_done - t_submit))s"

[ "$attempts" = 2 ] || fail "attempts=$attempts, expected 2"
[ "$outputs" = 1 ] || fail "$outputs output objects, expected 1"
[ "$new_owner" != "$OWNER" ] || fail "the stopped task finished the job itself"
worker_log "$JOB" "$since_ms" | grep -q "handing job back" || fail "no hand-back log line"
pass "handed back $((t_back - t_stop))s after SIGTERM, re-claimed by a new task after $((t_reclaim - t_stop))s, done $((t_done - t_stop))s after the stop; attempts=2, 1 output"
