# CloudWatch dashboard (free tier: 3 dashboards x 50 metrics). Gated by
# enable_compute because the API widgets need the ALB's identifiers.
#
# Running worker tasks: without Container Insights there's no RunningTaskCount,
# but the SampleCount of the service's CPUUtilization is one per running task
# per minute (checked against a deployment where two tasks overlapped).

locals {
  dash_queue   = aws_sqs_queue.jobs.name
  dash_dlq     = aws_sqs_queue.jobs_dlq.name
  dash_cluster = aws_ecs_cluster.main.name
  dash_worker  = "${local.name}-worker"
}

resource "aws_cloudwatch_dashboard" "main" {
  count = local.compute

  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Jobs backlog (scaling signal)", region = "ap-south-1", view = "timeSeries", period = 60
          metrics = [
            [{ expression = "FILL(visible,0)+FILL(inflight,0)", label = "backlog (visible + in flight)", id = "backlog" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", local.dash_queue, { id = "visible", stat = "Maximum", label = "visible" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesNotVisible", "QueueName", local.dash_queue, { id = "inflight", stat = "Maximum", label = "in flight" }],
          ]
          annotations = { horizontal = [{ value = 1, label = "scale-out threshold" }] }
          yAxis       = { left = { min = 0 } }
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Worker tasks running", region = "ap-south-1", view = "timeSeries", period = 60
          metrics = [
            [{ expression = "FILL(tasks,0)", label = "running worker tasks", id = "running" }],
            ["AWS/ECS", "CPUUtilization", "ClusterName", local.dash_cluster, "ServiceName", local.dash_worker, { id = "tasks", stat = "SampleCount", visible = false }],
          ]
          annotations = { horizontal = [{ value = 3, label = "max capacity" }] }
          yAxis       = { left = { min = 0, max = 4 } }
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 8, height = 6
        properties = {
          title = "DLQ depth", region = "ap-south-1", view = "timeSeries", period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", local.dash_dlq, { stat = "Maximum", label = "messages in DLQ" }],
          ]
          annotations = { horizontal = [{ value = 1, label = "alarm (> 0)" }] }
          yAxis       = { left = { min = 0 } }
        }
      },
      {
        type = "metric", x = 8, y = 6, width = 8, height = 6
        properties = {
          title = "API 5xx", region = "ap-south-1", view = "timeSeries", period = 60, stat = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.api[0].arn_suffix, { label = "target (app) 5xx" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.api[0].arn_suffix, { label = "ALB 5xx" }],
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type = "metric", x = 16, y = 6, width = 8, height = 6
        properties = {
          title = "API target response time", region = "ap-south-1", view = "timeSeries", period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.api[0].arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.api[0].arn_suffix, { stat = "p99", label = "p99" }],
          ]
          yAxis = { left = { min = 0, label = "seconds" } }
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 24, height = 6
        properties = {
          title = "Worker CPU", region = "ap-south-1", view = "timeSeries", period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", local.dash_cluster, "ServiceName", local.dash_worker, { stat = "Average", label = "average %" }],
            ["AWS/ECS", "CPUUtilization", "ClusterName", local.dash_cluster, "ServiceName", local.dash_worker, { stat = "Maximum", label = "maximum %" }],
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
    ]
  })
}
