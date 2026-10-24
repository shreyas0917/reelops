#!/usr/bin/env bash
# Drill 4: a message the worker can't handle ends in the DLQ and raises the alarm.
#
# A non-S3 message makes parse_event() raise; the worker logs "unhandled error;
# message left for retry" and doesn't delete it. SQS redelivers it after each
# 300 s visibility timeout; after maxReceiveCount (3) receives it moves to the
# DLQ, and the DLQ alarm goes to ALARM (email via SNS). The drill then checks
# the DLQ holds only its own message, purges it, and waits for the alarm to
# return to OK. Takes ~20-25 minutes.
#
# Safety: aborts if the DLQ isn't empty at the start; purges only after
# confirming the DLQ's single message carries this run's marker.
# Usage: scripts/chaos/test4_dlq_alarm.sh
TEST_NAME=test4-dlq-alarm
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
ALARM="${ALARM:-reelops-dev-jobs-dlq-not-empty}"

alarm_state() { aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text; }
alarm_is() { [ "$(alarm_state)" = "$1" ]; }
dlq_count() {
  echo $(($(queue_attr "$DLQ" ApproximateNumberOfMessages) + $(queue_attr "$DLQ" ApproximateNumberOfMessagesNotVisible)))
}

[ "$(dlq_count)" = 0 ] || fail "DLQ is not empty; refusing to run (it may hold real failed messages)"
log "DLQ empty; alarm $ALARM is $(alarm_state)"

MARKER="chaos-drill-$(cat /proc/sys/kernel/random/uuid)"
BODY="{\"drill\": \"$MARKER\", \"note\": \"not an S3 event: the worker must leave it for retry\"}"
since_ms=$(epoch_ms)
t_send=$(epoch)
aws sqs send-message --queue-url "$QUEUE" --message-body "$BODY" >/dev/null
log "sent malformed message (marker $MARKER)"

in_dlq() { [ "$(queue_attr "$DLQ" ApproximateNumberOfMessages)" != 0 ]; }
wait_until 1500 "message moved to the DLQ" in_dlq
t_dlq=$(epoch)
log "message in the DLQ $((t_dlq - t_send))s after sending"

wait_until 600 "alarm $ALARM in ALARM" alarm_is ALARM
t_alarm=$(epoch)
log "alarm ALARM $((t_alarm - t_dlq))s after the move (email sent via SNS)"

# One line per receive: the traceback arrives as one log event per line, and
# only its last line ("ValueError: ...") is counted.
echo "---- worker log: receives that couldn't be handled"
aws logs filter-log-events --log-group-name "$WORKER_LOGS" --start-time "$since_ms" \
  --filter-pattern '"ValueError: not an S3 event message"' --output json | python3 -I -c '
import datetime, json, sys
for e in json.load(sys.stdin)["events"]:
    t = datetime.datetime.fromtimestamp(e["timestamp"] / 1000, datetime.UTC).strftime("%H:%M:%S")
    print(t, e["logStreamName"].rsplit("/", 1)[-1][:8], e["message"].strip().splitlines()[-1][:110])' | tee "$STATE/test4-receives.txt"
echo "----"
receives=$(wc -l <"$STATE/test4-receives.txt")

# Only purge if the DLQ holds exactly our message.
[ "$(dlq_count)" = 1 ] || fail "DLQ holds $(dlq_count) messages, expected only the drill's; not purging"
peek=$(aws sqs receive-message --queue-url "$DLQ" --visibility-timeout 5 --wait-time-seconds 5 \
  --attribute-names ApproximateReceiveCount --query 'Messages[0].[Body,Attributes.ApproximateReceiveCount]' --output text)
grep -q "$MARKER" <<<"$peek" || fail "DLQ message isn't the drill's; not purging"
log "DLQ message is the drill's (receive count $(cut -f2 <<<"$peek"), incl. this check)"
sleep 6 # let the peek's visibility lapse
aws sqs purge-queue --queue-url "$DLQ"
t_purge=$(epoch)
log "DLQ purged"

wait_until 900 "alarm back to OK" alarm_is OK
t_ok=$(epoch)
log "alarm OK $((t_ok - t_purge))s after the purge"

echo "---- alarm history"
aws cloudwatch describe-alarm-history --alarm-name "$ALARM" --history-item-type StateUpdate \
  --start-date "$(date -u -d "@$t_send" +%FT%TZ)" --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text | sort
echo "----"

[ "$receives" = 3 ] || fail "worker logged $receives failed receives, expected 3"
pass "3 receives, in the DLQ $((t_dlq - t_send))s after sending, alarm ALARM $((t_alarm - t_dlq))s later; purged, alarm OK $((t_ok - t_purge))s after the purge"
