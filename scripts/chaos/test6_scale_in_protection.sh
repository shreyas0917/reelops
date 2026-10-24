#!/usr/bin/env bash
# Drill 6: scale-in must stop an idle worker, never the one processing a job.
#
# One ~40-minute job and two 31 s jobs give a backlog of 3: autoscaling runs
# two workers. When the short jobs finish, the backlog drops to 1 and
# autoscaling itself sets the desired count to 1 while the long job is still
# processing. ECS must stop the idle task (task protection off) and keep the
# busy one (protection on), which finishes its job and turns protection off.
# Then autoscaling scales the service in to 0 on its own.
#
# Why autoscaling and not a manual `update-service --desired-count`: while the
# scale-out alarm is in ALARM, step scaling re-applies its capacity every
# minute and reverts a manual change (run 1 of this drill, 12 s).
#
# Needs: the live stack, samples/output/ui-fixture/recording.mp4.
# Usage: scripts/chaos/test6_scale_in_protection.sh
TEST_NAME=test6-scale-in-protection
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
require_only_ecs_workers

SHORT="samples/output/ui-fixture/recording.mp4"
LONG="$STATE/walkthrough-40min.mp4"
[ -f "$SHORT" ] || fail "missing $SHORT; run scripts/make_ui_fixture.sh first"
if [ ! -f "$LONG" ]; then
  # 80 x 31 s: long enough to still be processing when autoscaling scales in.
  ffmpeg -hide_banner -loglevel error -y -stream_loop 79 -i "$SHORT" -c copy "$LONG"
fi
log "inputs: $(basename "$LONG") ($(($(stat -c %s "$LONG") / 1048576)) MB, $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$LONG" | cut -d. -f1)s) + 2 x 31 s"

service_counts() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$WORKER_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text | tr '\t' '/'
}
protection() { # protection <task-arn>: true/false
  aws ecs get-task-protection --cluster "$CLUSTER" --tasks "$1" \
    --query 'protectedTasks[0].protectionEnabled' --output text | tr '[:upper:]' '[:lower:]'
}
log "worker service desired/running: $(service_counts)"

since_ms=$(epoch_ms)
t0=$(epoch)
LONG_JOB=$(submit_job "$LONG")
SHORT1=$(submit_job "$SHORT")
SHORT2=$(submit_job "$SHORT")
log "submitted long $LONG_JOB and short $SHORT1, $SHORT2"

two_running() { [ "$(service_counts)" = "2/2" ]; }
wait_until 900 "autoscaling runs 2 workers" two_running
log "2 workers running $(($(epoch) - t0))s after submitting"

shorts_done() { job_is "$SHORT1" "done" && job_is "$SHORT2" "done" && job_is "$LONG_JOB" processing; }
wait_until 900 "short jobs done while the long job is processing" shorts_done

STREAM=$(job_stream "$LONG_JOB" "$since_ms")
BUSY_ID=${STREAM##*/}
mapfile -t TASKS < <(running_tasks "$WORKER_SERVICE" | tr '\t' '\n')
BUSY="" IDLE=""
for t in "${TASKS[@]}"; do
  if [ "${t##*/}" = "$BUSY_ID" ]; then BUSY=$t; else IDLE=$t; fi
done
[ -n "$BUSY" ] && [ -n "$IDLE" ] || fail "couldn't tell the busy task ($BUSY_ID) from the idle one"
log "busy ${BUSY_ID:0:8} protection=$(protection "$BUSY"); idle ${IDLE##*/} protection=$(protection "$IDLE")"
[ "$(protection "$BUSY")" = true ] || fail "busy task is not protected"
[ "$(protection "$IDLE")" = false ] || fail "idle task is protected"

# Hands off: autoscaling should now scale in from 2 to 1 by itself.
t_wait=$(epoch)
one_running() { [ "$(running_tasks "$WORKER_SERVICE" | wc -w)" = 1 ]; }
wait_until 600 "autoscaling scales in to 1 task" one_running
t_in=$(epoch)
running_tasks "$WORKER_SERVICE" | grep -q "$BUSY_ID" || fail "ECS stopped the BUSY task"
job_is "$LONG_JOB" processing || fail "long job finished before the scale-in; drill inconclusive"
log "scale-in: ECS stopped the idle task $((t_in - t_wait))s after the short jobs finished; busy task kept; long job: $(job_summary "$LONG_JOB")"

wait_until 2400 "long job done on the protected task" job_is "$LONG_JOB" "done"
t_done=$(epoch)
log "long job done $((t_done - t_in))s after the scale-in: $(job_summary "$LONG_JOB"), outputs=$(output_count "$LONG_JOB")"

echo "---- scaling activities and service events since the drill started"
aws application-autoscaling describe-scaling-activities --service-namespace ecs \
  --resource-id "service/$CLUSTER/$WORKER_SERVICE" --max-items 8 \
  --query 'ScalingActivities[].[StartTime,Description]' --output text | sort | cut -c12-19,34- |
  awk -v s="$(date -u -d "@$t0" +%H:%M:%S)" '$1 >= s'
aws ecs describe-services --cluster "$CLUSTER" --services "$WORKER_SERVICE" \
  --query 'services[0].events[:8].[createdAt,message]' --output text | sort | cut -c12-19,34- |
  awk -v s="$(date -u -d "@$t0" +%H:%M:%S)" '$1 >= s' | redact
echo "---- busy task log (claims, protection, done)"
aws logs filter-log-events --log-group-name "$WORKER_LOGS" --log-stream-names "$STREAM" --start-time "$since_ms" \
  --output json | python3 -I -c '
import datetime, json, sys
for e in json.load(sys.stdin)["events"]:
    m = e["message"]
    if any(k in m for k in ("claimed by", "task protection", "done ->")):
        t = datetime.datetime.fromtimestamp(e["timestamp"] / 1000, datetime.UTC).strftime("%H:%M:%S")
        print(t, m.split("reelops_worker.", 1)[-1].rstrip()[:130])' | redact
echo "----"

# Autoscaling was never suspended: its scale-in alarm should take the rest.
at_zero() { [ "$(service_counts)" = "0/0" ]; }
wait_until 1800 "autoscaling scales the workers in to 0" at_zero
t_zero=$(epoch)
log "workers at 0, $((t_zero - t_done))s after the last job"

[ "$(job_field "$LONG_JOB" attempts)" = 1 ] || fail "long job was retried (attempts $(job_field "$LONG_JOB" attempts))"
[ "$(output_count "$LONG_JOB")" = 1 ] || fail "expected 1 output for the long job"
pass "autoscaling scale-in stopped the idle task and kept the protected one, which finished its job (attempts=1, 1 output); workers at 0 $((t_zero - t_done))s after the last job"
