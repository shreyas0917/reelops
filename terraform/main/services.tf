# ECS services. Created only when var.enable_compute is true. The worker's
# desired_count is managed by autoscaling (autoscaling.tf).

resource "aws_ecs_service" "api" {
  count = local.compute

  name            = "${local.name}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true # no NAT: the only route to ECR, Logs, DynamoDB/S3 endpoints
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api[0].arn
    container_name   = "api"
    container_port   = 8000
  }

  # Rolling deploy with no capacity drop: start the new task, wait until the
  # ALB reports it healthy, then stop the old one.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  # A deployment whose tasks keep failing is marked failed and rolled back.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  # Ignore ALB health checks while a new task starts (the API starts in ~2 s).
  health_check_grace_period_seconds = 30

  # Fail the apply if the service doesn't stabilise; tag tasks for cost reports.
  wait_for_steady_state = true
  propagate_tags        = "SERVICE"

  # ECS rejects a target group that isn't attached to a load balancer yet.
  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "worker" {
  count = local.compute

  name            = "${local.name}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  # Only used when the service is created (e.g. on resume); afterwards the
  # autoscaler owns desired_count (see lifecycle below and autoscaling.tf).
  desired_count = 1
  launch_type   = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = true # no NAT: the only route to ECR, SQS, Polly, Logs
  }

  # Two workers briefly overlap during a deploy; the claim logic handles it,
  # and the old one finishes or hands back its job on SIGTERM.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  wait_for_steady_state = true
  propagate_tags        = "SERVICE"

  # Without this, every plan would try to reset the autoscaler's count to 1:
  # stopping busy workers after a scale-out, or starting one after scale-in.
  lifecycle {
    ignore_changes = [desired_count]
  }
}
