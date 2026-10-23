# ECS cluster and log groups. Task definitions and services are in
# task_definitions.tf and services.tf.

# Created here (not by the awslogs driver) so retention is set and Terraform
# owns them; auto-created groups keep logs forever by default.
resource "aws_cloudwatch_log_group" "api" {
  name              = "/reelops/dev/api"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/reelops/dev/worker"
  retention_in_days = 7
}

# A Fargate cluster is free; tasks are what cost. Container Insights is off:
# its extra metrics and performance logs are billed, and the free per-service
# CPU/memory metrics (plus SQS metrics) cover dev and Phase 5 autoscaling.
resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}
