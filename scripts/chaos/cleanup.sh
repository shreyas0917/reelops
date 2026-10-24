#!/usr/bin/env bash
# Delete what the failure drills created, and nothing else: for each job id in
# samples/output/chaos/jobs.txt, its raw upload (raw/<id>/), its output video
# (output/<id>.mp4) and its job item. Safe to re-run.
# Usage: scripts/chaos/cleanup.sh
TEST_NAME=cleanup
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

[ -s "$JOBS_FILE" ] || { log "nothing to clean ($JOBS_FILE is empty)"; exit 0; }
n=0
while read -r id _; do
  # Only ever a job id (uuid), never a prefix that could match other jobs.
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
  aws s3 rm "s3://$BUCKET/raw/$id/" --recursive --only-show-errors
  aws s3 rm "s3://$BUCKET/output/$id.mp4" --only-show-errors
  aws dynamodb delete-item --table-name "$TABLE" --key "{\"job_id\": {\"S\": \"$id\"}}"
  n=$((n + 1))
done <"$JOBS_FILE"
mv "$JOBS_FILE" "$JOBS_FILE.cleaned-$(date -u +%Y%m%dT%H%M%SZ)"
pass "removed $n drill jobs (uploads, outputs, job items)"
