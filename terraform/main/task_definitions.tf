# Fargate task definitions. Images are referenced by immutable SHA tags; a new
# tag creates a new revision. Both images already run as non-root uid 10001.

# Image tags for the checked-out commit, computed by the same script CI and
# push_images.sh use, so a plain `terraform plan` always means "deploy this
# commit". Before, tags came from a git-ignored images.auto.tfvars that only
# push_images.sh wrote: once deploys moved to CI it went stale, and a local
# plan wanted to roll both services back to old images.
data "external" "image_tags" {
  program = ["bash", "${path.module}/../../scripts/image_tags.sh", "--json"]
}

locals {
  api_image_tag    = coalesce(var.api_image_tag, data.external.image_tags.result.api)
  worker_image_tag = coalesce(var.worker_image_tag, data.external.image_tags.result.worker)
}

locals {
  # Same values scripts/env_from_tf.sh writes for docker compose.
  common_env = [
    { name = "AWS_REGION", value = "ap-south-1" },
    { name = "AWS_DEFAULT_REGION", value = "ap-south-1" },
    { name = "REELOPS_MEDIA_BUCKET", value = aws_s3_bucket.media.bucket },
    { name = "REELOPS_JOBS_TABLE", value = aws_dynamodb_table.jobs.name },
  ]

  # Non-blocking: if CloudWatch is slow the app never blocks on stdout; logs
  # can be dropped only if the 25 MB buffer fills.
  log_options = {
    "awslogs-region"  = "ap-south-1"
    "mode"            = "non-blocking"
    "max-buffer-size" = "25m"
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # 0.25 vCPU
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.api_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = "api"
    image        = "${aws_ecr_repository.this["api"].repository_url}:${local.api_image_tag}"
    essential    = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment  = local.common_env
    # Tested: the API writes nothing to disk.
    readonlyRootFilesystem = true

    # ECS replaces the task if this fails; the ALB has its own check.
    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }

    logConfiguration = {
      logDriver = "awslogs"
      options   = merge(local.log_options, { "awslogs-group" = aws_cloudwatch_log_group.api.name, "awslogs-stream-prefix" = "api" })
    }
  }])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048 # 2 vCPU
  memory                   = 4096
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.worker_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Scratch space on the task's ephemeral storage (20 GiB default). The only
  # writable path: the root filesystem is read-only.
  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    # Fargate creates the volume as root:root 0755, so the non-root worker
    # can't write to it (Docker's local --tmpfs is 1777, which hid this).
    # This container runs as root for ~1 s, makes it a normal /tmp (1777),
    # and exits; the worker starts only after it succeeds.
    {
      name                   = "init-tmp"
      image                  = "${aws_ecr_repository.this["worker"].repository_url}:${local.worker_image_tag}"
      essential              = false
      user                   = "0"
      entryPoint             = ["chmod", "1777", "/tmp"]
      command                = []
      readonlyRootFilesystem = true
      mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.log_options, { "awslogs-group" = aws_cloudwatch_log_group.worker.name, "awslogs-stream-prefix" = "init" })
      }
    },
    {
      name        = "worker"
      image       = "${aws_ecr_repository.this["worker"].repository_url}:${local.worker_image_tag}"
      essential   = true
      command     = ["consume"]
      environment = concat(local.common_env, [{ name = "REELOPS_JOBS_QUEUE_URL", value = aws_sqs_queue.jobs.url }])
      dependsOn   = [{ containerName = "init-tmp", condition = "SUCCESS" }]
      # The pipeline only needs a writable /tmp (made writable by init-tmp).
      readonlyRootFilesystem = true
      mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]

      # init as PID 1 forwards SIGTERM and reaps orphaned ffmpeg (Phase 3 fix).
      linuxParameters = { initProcessEnabled = true }
      # SIGTERM -> SIGKILL window; above the worker's 20 s job grace period.
      stopTimeout = 30

      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.log_options, { "awslogs-group" = aws_cloudwatch_log_group.worker.name, "awslogs-stream-prefix" = "worker" })
      }
    },
  ])
}
