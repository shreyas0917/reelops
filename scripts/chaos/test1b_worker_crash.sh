#!/usr/bin/env bash
# Drill 1b: a worker dies mid-job without any warning (SIGKILL).
#
# Unlike `ecs stop-task` (SIGTERM, graceful hand-back: drill 1), a hard crash
# runs no shutdown code. Recovery then relies on two timers: the job's lease
# goes stale 240 s after the last heartbeat, and the SQS message reappears
# when its visibility timeout (300 s) runs out. An ECS worker must then claim
# the stale lease (attempts 1 -> 2) and finish the job, with one output.
#
# ECS has no way to SIGKILL a task, so ONE deliberate drill worker runs on the
# dev box from the deployed ECR image, claims the job, and is killed with
# `docker kill -s KILL`. It is always removed on exit.
#
# Needs: the live stack, docker, aws CLI (ECR pull via the instance role),
# samples/output/chaos/long-walkthrough.mp4 (drill 1 creates it).
# Usage: scripts/chaos/test1b_worker_crash.sh
TEST_NAME=test1b-worker-crash
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

DRILL=reelops-drill-worker
INPUT="$STATE/walkthrough-8min.mp4"
[ -f "$INPUT" ] || fail "missing $INPUT; run scripts/chaos/test1_worker_killed.sh first"
remove_drill_worker() { docker rm -f "$DRILL" >/dev/null 2>&1 || true; }
trap remove_drill_worker EXIT
require_only_ecs_workers

# The deployed worker image, so the crash happens in production code.
REPO=$(terraform -chdir=terraform/main output -json ecr_repository_urls | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["worker"])')
# From the live task definition, not scripts/image_tags.sh: that reads this
# checkout's git history, which may not be what's deployed.
TAG=$(aws ecs describe-task-definition --task-definition "$WORKER_SERVICE" \
  --query 'taskDefinition.containerDefinitions[0].image' --output text | sed 's/.*://')
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}" >/dev/null
docker pull -q "$REPO:$TAG" >/dev/null
log "drill worker image: reelops-worker:$TAG (the deployed tag)"

# Two consumers would race for the message: wait until ECS has scaled to zero.
# runningCount, not list-tasks --desired-status RUNNING: a task being scaled in
# leaves that list at once but still long-polls (and releases what it gets).
no_ecs_workers() {
  [ "$(aws ecs describe-services --cluster "$CLUSTER" --services "$WORKER_SERVICE" \
    --query 'services[0].[runningCount,pendingCount]' --output text | tr -s '\t' ' ')" = "0 0" ]
}
log "waiting for ECS workers to scale in to 0 (needs 10 idle minutes)..."
wait_until 1800 "ECS workers scaled in to 0" no_ecs_workers
log "ECS workers: 0"

docker run -d --name "$DRILL" --init -e AWS_REGION="$REGION" \
  -e REELOPS_JOBS_QUEUE_URL="$QUEUE" -e REELOPS_MEDIA_BUCKET="$BUCKET" -e REELOPS_JOBS_TABLE="$TABLE" \
  "$REPO:$TAG" consume >/dev/null
DRILL_HOST=$(docker inspect -f '{{.Config.Hostname}}' "$DRILL")
log "drill worker $DRILL started (hostname $DRILL_HOST)"

t_submit=$(epoch); since_ms=$(epoch_ms)
JOB=$(submit_job "$INPUT")
log "submitted job $JOB"
wait_until 120 "drill worker claims the job" job_is "$JOB" processing
owner=$(job_field "$JOB" worker_id)
[[ "$owner" == "$DRILL_HOST"-* ]] || fail "job was claimed by $owner, not the drill worker"
t_claim=$(epoch)
log "claimed by the drill worker after $((t_claim - t_submit))s: $(job_summary "$JOB") worker_id=$owner"

sleep 20 # mid-job, before the first 60 s heartbeat
job_is "$JOB" processing || fail "job left processing before the kill: $(job_summary "$JOB")"
docker kill -s KILL "$DRILL" >/dev/null
t_kill=$(epoch)
log "drill worker SIGKILLed $((t_kill - t_claim))s after the claim; its last log lines:"
docker logs "$DRILL" 2>&1 | tail -3 | sed 's/^/    /'
remove_drill_worker

# Recovery timeline: the message reappears, then an ECS worker takes the stale lease.
t_visible=""
recovered() {
  if [ -z "$t_visible" ] && [ "$(queue_attr "$QUEUE" ApproximateNumberOfMessages)" != 0 ]; then
    t_visible=$(epoch)
    log "message visible again $((t_visible - t_claim))s after the claim"
  fi
  [ "$(job_field "$JOB" attempts)" = 2 ]
}
wait_until 900 "an ECS worker takes over the stale lease (attempts 2)" recovered
t_reclaim=$(epoch)
new_owner=$(job_field "$JOB" worker_id)
log "re-claimed $((t_reclaim - t_claim))s after the first claim: $(job_summary "$JOB") worker_id=$new_owner"

wait_until 900 "job done" job_is "$JOB" "done"
t_done=$(epoch)
log "done $((t_done - t_kill))s after the kill: $(job_summary "$JOB")"

echo "---- ECS worker log for $JOB (time, task, message)"
worker_log "$JOB" "$since_ms"
echo "----"

outputs=$(output_count "$JOB")
attempts=$(job_field "$JOB" attempts)
log "attempts=$attempts outputs=$outputs first-owner=$owner final-owner=$new_owner"
log "timings: kill->visible=$(( ${t_visible:-$t_reclaim} - t_kill ))s claim->reclaim=$((t_reclaim - t_claim))s kill->done=$((t_done - t_kill))s total=$((t_done - t_submit))s"

[ "$attempts" = 2 ] || fail "attempts=$attempts, expected 2"
# Since the drill fixes the claim line shows both counts; the take-over must
# be attempt 2 whatever SQS's receive count says.
takeover=$(worker_log "$JOB" "$since_ms" | grep -m1 "claimed by" || true)
if grep -q "attempt " <<<"$takeover"; then
  grep -q "(attempt 2," <<<"$takeover" || fail "take-over isn't attempt 2: $takeover"
fi
[ "$outputs" = 1 ] || fail "$outputs output objects, expected 1"
[[ "$new_owner" != "$DRILL_HOST"-* ]] || fail "final owner is the drill worker"
[ $((t_reclaim - t_claim)) -ge 240 ] || fail "taken over after $((t_reclaim - t_claim))s, before the 240 s lease could expire"
[ -z "$(docker ps -aq --filter "name=^${DRILL}$")" ] || fail "drill worker container still exists"
pass "SIGKILLed worker's job taken over by ECS $((t_reclaim - t_claim))s after the claim (lease 240 s, visibility 300 s), done $((t_done - t_kill))s after the kill; attempts=2, 1 output, no local worker left"
