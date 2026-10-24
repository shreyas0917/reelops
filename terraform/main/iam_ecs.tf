# IAM for ECS tasks.
#
# Execution role: used by the ECS agent to pull the image and write logs.
# Task roles: the credentials the application code gets (boto3 finds them via
# the ECS credentials endpoint). Each grants only what that service calls.
# No S3 statement names anything but the media bucket, so the Terraform state
# bucket is unreachable (IAM denies anything not explicitly allowed).

# Only ECS tasks in this account may assume these roles (confused-deputy guard).
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:ap-south-1:${local.account_id}:*"]
    }
  }
}

# ---- execution role (ECS agent) ---------------------------------------------

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# AWS-managed: ECR auth/pull and CloudWatch Logs writes. Its resources are "*";
# it belongs to the agent, not the app. Tighter option: a custom policy scoped
# to our two repos and log groups (ecr:GetAuthorizationToken still needs "*").
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---- API task role ------------------------------------------------------------

data "aws_iam_policy_document" "api_task" {
  # Create jobs and read their status.
  statement {
    sid       = "JobsTable"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.jobs.arn]
  }

  # The API never touches video bytes, but presigned URLs are requests signed
  # with this role's credentials, so S3 checks this role's permissions when
  # the browser uses them.
  statement {
    sid       = "SignUploadUrls"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.media.arn}/raw/*"]
  }

  statement {
    sid       = "SignDownloadUrls"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.media.arn}/output/*"]
  }

  # The web UI's "Original" toggle plays the raw upload through a presigned
  # inline GET. Read-only, and still only this bucket's raw/ prefix.
  statement {
    sid       = "SignOriginalPreviewUrls"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.media.arn}/raw/*"]
  }
}

resource "aws_iam_role" "api_task" {
  name               = "${local.name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "api_task" {
  name   = "api"
  role   = aws_iam_role.api_task.id
  policy = data.aws_iam_policy_document.api_task.json
}

# ---- worker task role ---------------------------------------------------------

data "aws_iam_policy_document" "worker_task" {
  # Poll, delete after done, heartbeat/hand back, read queue depth. Main queue
  # only; SQS moves messages to the DLQ itself.
  statement {
    sid = "JobsQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.jobs.arn]
  }

  # Download the upload (boto3's HeadObject also maps to s3:GetObject).
  statement {
    sid       = "ReadUploads"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.media.arn}/raw/*"]
  }

  # Upload the result. s3:PutObject covers multipart uploads; boto3's
  # upload_file also aborts a failed multipart upload, which needs its own
  # permission (the bucket lifecycle cleans up after 1 day only as a backstop).
  statement {
    sid       = "WriteOutputs"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.media.arn}/output/*"]
  }

  # Read the job, claim it, heartbeat, mark done/failed.
  statement {
    sid       = "JobsTable"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.jobs.arn]
  }

  # Task scale-in protection while holding a job. The worker calls the ECS
  # agent endpoint, and the agent makes this API call with the task role.
  # Only set (never read) protection, only for tasks in our cluster.
  statement {
    sid       = "TaskScaleInProtection"
    actions   = ["ecs:UpdateTaskProtection"]
    resources = ["arn:aws:ecs:ap-south-1:${local.account_id}:task/${aws_ecs_cluster.main.name}/*"]
  }

  # Resource "*" is unavoidable: DescribeVoices has no resource ARN, and
  # SynthesizeSpeech can only be scoped to lexicons, which we don't use.
  # Narrowed to our region instead.
  statement {
    sid       = "VoiceOver"
    actions   = ["polly:SynthesizeSpeech", "polly:DescribeVoices"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-south-1"]
    }
  }
}

resource "aws_iam_role" "worker_task" {
  name               = "${local.name}-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "worker_task" {
  name   = "worker"
  role   = aws_iam_role.worker_task.id
  policy = data.aws_iam_policy_document.worker_task.json
}
