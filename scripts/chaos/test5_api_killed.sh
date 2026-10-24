#!/usr/bin/env bash
# Drill 5: stop the API task while a client probes /healthz every 2 s.
#
# The API service runs ONE task. `stop-task` makes ECS deregister it from the
# target group first (target "draining", deregistration delay 30 s), so the
# ALB has no target and answers 503. The service starts a replacement at once;
# it serves again once registered and healthy (2 checks, 15 s apart).
# Measures the downtime seen by the client and records target states and ECS
# service events.
#
# Needs: the live stack; this machine's IP in allowed_cidrs.
# Usage: scripts/chaos/test5_api_killed.sh
TEST_NAME=test5-api-killed
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

PROBES="$STATE/test5-probes.txt"
TG=$(aws ecs describe-services --cluster "$CLUSTER" --services "$API_SERVICE" \
  --query 'services[0].loadBalancers[0].targetGroupArn' --output text)
targets() {
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text | tr '\t\n' ': ' | sed 's/ $//'
}

# Probe loop: "epoch-ms HH:MM:SS status seconds" every 2 s.
: >"$PROBES"
probe_loop() {
  while :; do
    printf '%s %s %s\n' "$(epoch_ms)" "$(now)" \
      "$(curl -s -o /dev/null -m 3 -w '%{http_code} %{time_total}' "$API/healthz" || echo '000 3')" >>"$PROBES"
    sleep 2
  done
}
probe_loop &
PROBER=$!
trap 'kill "$PROBER" 2>/dev/null || true' EXIT
sleep 10
grep -q ' 200 ' "$PROBES" || fail "/healthz isn't answering 200 before the drill"
log "baseline: $(grep -c ' 200 ' "$PROBES") probes, all 200; targets: $(targets)"

TASK=$(running_tasks "$API_SERVICE" | awk '{print $1}')
[ -n "$TASK" ] || fail "no running API task"
t_stop_ms=$(epoch_ms)
aws ecs stop-task --cluster "$CLUSTER" --task "$TASK" --reason "chaos drill: $TEST_NAME" >/dev/null
log "stop-task sent to API task ${TASK##*/}"

# Watch target states until the client has seen 200s for 30 s after an outage.
last_targets=""
recovered() {
  local t
  t=$(targets)
  # stderr: wait_until silences the probe's stdout
  if [ "$t" != "$last_targets" ]; then log "targets: ${t:-none}" >&2; last_targets=$t; fi
  python3 -I - "$PROBES" "$t_stop_ms" <<'EOF'
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if int(r[0]) >= int(sys.argv[2])]
down = [i for i, r in enumerate(rows) if r[2] != "200"]
if not down:
    sys.exit(1)
after = rows[down[-1] + 1:]
sys.exit(0 if len(after) >= 15 else 1)  # 15 probes x 2 s = 30 s of 200s
EOF
}
wait_until 600 "API back and stable for 30 s" recovered
kill "$PROBER" 2>/dev/null || true

echo "---- probes around the outage (time, HTTP status, seconds)"
python3 -I - "$PROBES" "$t_stop_ms" <<'EOF'
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
start = int(sys.argv[2])
rows = [r for r in rows if int(r[0]) >= start - 6000]
down = [i for i, r in enumerate(rows) if r[2] != "200"]
for r in rows[max(0, down[0] - 2): down[-1] + 3]:
    print(r[1], r[2], r[3])
EOF
echo "---- ECS service events"
aws ecs describe-services --cluster "$CLUSTER" --services "$API_SERVICE" \
  --query 'services[0].events[:6].[createdAt,message]' --output text | sort | cut -c12-19,34- | redact
echo "----"

read -r first_fail last_fail first_ok codes < <(python3 -I - "$PROBES" "$t_stop_ms" <<'EOF'
import collections, sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if int(r[0]) >= int(sys.argv[2])]
down = [i for i, r in enumerate(rows) if r[2] != "200"]
codes = collections.Counter(rows[i][2] for i in down)
print(rows[down[0]][0], rows[down[-1]][0], rows[down[-1] + 1][0],
      ",".join(f"{c}x{n}" for c, n in sorted(codes.items())))
EOF
)
downtime=$(((first_ok - first_fail) / 1000))
log "failures from $(((first_fail - t_stop_ms) / 1000))s to $(((last_fail - t_stop_ms) / 1000))s after the stop ($codes); back to 200 $(((first_ok - t_stop_ms) / 1000))s after the stop"
log "client-visible downtime: ${downtime}s (single API task); targets now: $(targets)"
[ "$(running_tasks "$API_SERVICE" | wc -w)" = 1 ] || fail "expected 1 running API task"
[ "$(running_tasks "$API_SERVICE")" != "$TASK" ] || fail "the stopped task is still the running one"
pass "API stopped and replaced; downtime ${downtime}s ($codes), back to 200 $(((first_ok - t_stop_ms) / 1000))s after the stop, stable 30 s"
