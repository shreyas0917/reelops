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
