# Worker autoscaling on SQS backlog: 0 to 3 tasks. Gated by enable_compute.
#
# Application Auto Scaling owns the worker service's desired_count (the
# service ignores changes to it), using AWS's service-linked role
# AWSServiceRoleForApplicationAutoScaling_ECSService (created on first use).

resource "aws_appautoscaling_target" "worker" {
  count = local.compute

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 0
  max_capacity       = 3
}

# Backlog = visible (waiting) + not visible (being processed). In-flight
# messages must count: a worker mid-job leaves "visible" at 0, and scaling in
# on that alone would stop the worker while it is still working.
locals {
  backlog_queries = {
    visible  = "ApproximateNumberOfMessagesVisible"
    inflight = "ApproximateNumberOfMessagesNotVisible"
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_scale_out" {
  count = local.compute

  alarm_name          = "${local.name}-worker-scale-out"
  alarm_description   = "Jobs backlog >= 1: run worker tasks (step scaling)."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  # No data never starts tasks.
  treat_missing_data = "notBreaching"

  dynamic "metric_query" {
    for_each = local.backlog_queries
    content {
      id          = metric_query.key
      return_data = false
      metric {
        namespace   = "AWS/SQS"
        metric_name = metric_query.value
        dimensions  = { QueueName = aws_sqs_queue.jobs.name }
        period      = 60
        stat        = "Maximum" # one message for part of a minute still counts as 1
      }
    }
  }

  metric_query {
    id          = "backlog"
    expression  = "visible + inflight"
    label       = "Jobs backlog (visible + in flight)"
    return_data = true
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_scale_in" {
  count = local.compute

  alarm_name          = "${local.name}-worker-scale-in"
  alarm_description   = "Jobs backlog 0 for 10 minutes: scale workers to 0."
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  # SQS stops publishing metrics for an inactive queue; no data means idle.
  # Otherwise the alarm would sit in INSUFFICIENT_DATA and never scale to 0.
  treat_missing_data = "breaching"

  dynamic "metric_query" {
    for_each = local.backlog_queries
    content {
      id          = metric_query.key
      return_data = false
      metric {
        namespace   = "AWS/SQS"
        metric_name = metric_query.value
        dimensions  = { QueueName = aws_sqs_queue.jobs.name }
        period      = 60
        stat        = "Maximum"
      }
    }
  }

  metric_query {
    id          = "backlog"
    expression  = "visible + inflight"
    label       = "Jobs backlog (visible + in flight)"
    return_data = true
  }
}
