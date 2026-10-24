# Alerting: any message in the DLQ -> CloudWatch alarm -> SNS -> email.

# Not encrypted with the AWS-managed aws/sns key: CloudWatch alarms can't
# publish to a topic using it (a customer-managed key would be needed).
# Alarm messages carry metadata only, no job data.
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

# Created as "pending confirmation": AWS emails a link that must be clicked
# before anything is delivered. Unconfirmed subscriptions can't be deleted by
# Terraform; AWS removes them after 3 days.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# A message only reaches the DLQ after 3 failed receives, so any message there
# needs a human. SQS metrics can lag by a few minutes (longer after the queue
# has been idle).
resource "aws_cloudwatch_metric_alarm" "jobs_dlq_not_empty" {
  alarm_name        = "${local.name}-jobs-dlq-not-empty"
  alarm_description = "Messages in ${aws_sqs_queue.jobs_dlq.name}: jobs failed 3 times. Inspect, fix, then redrive or purge."

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = aws_sqs_queue.jobs_dlq.name
  }
  statistic           = "Maximum" # one message must not be averaged away
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # Idle queues send no data points; that isn't a failure.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn] # also email when it clears
}

# A worker gave up on a job: its 3 real attempts failed (consumer.py, "failed
# on final attempt N; giving up"), or every earlier attempt died mid-job (the
# crash-loop guard, "gave up after N attempts that never finished"). The user
# sees "failed"; since PR #9 the message is deleted rather than sent to the
# DLQ, so this is the only operator signal. Tested with
# `aws logs test-metric-filter` against the worker's real lines: matches both,
# not "error on attempt 1; will retry", tracebacks or other lines.
# Not gated on enable_compute: the log group and SNS topic stay when paused.
resource "aws_cloudwatch_log_metric_filter" "worker_gave_up" {
  name           = "${local.name}-worker-gave-up"
  log_group_name = aws_cloudwatch_log_group.worker.name
  pattern        = "?\"; giving up\" ?\"attempts that never finished\""

  metric_transformation {
    namespace     = "ReelOps"
    name          = "WorkerGaveUp"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_gave_up" {
  alarm_name        = "${local.name}-worker-gave-up"
  alarm_description = "A worker gave up on a job after its retries (see ${aws_cloudwatch_log_group.worker.name}: \"giving up\" / \"never finished\"). The user sees the job as failed."

  namespace           = aws_cloudwatch_log_metric_filter.worker_gave_up.metric_transformation[0].namespace
  metric_name         = aws_cloudwatch_log_metric_filter.worker_gave_up.metric_transformation[0].name
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  # No log lines, no data points: that's a quiet worker, not a failure.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
