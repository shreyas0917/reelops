# Job queue: S3 "object created" events for raw/ uploads -> worker.

resource "aws_sqs_queue" "jobs_dlq" {
  name = "${local.name}-jobs-dlq"
  # Longer than the main queue's retention: a message keeps its original
  # enqueue timestamp when it moves to a standard DLQ.
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name = "${local.name}-jobs"
  # How long a received message stays hidden. If the worker dies, the message
  # reappears after this and is retried. Slowest job so far ~30 s: ~10x headroom.
  visibility_timeout_seconds = 300
  # Long polling: ReceiveMessage waits up to 20 s for a message instead of
  # returning empty immediately (fewer, cheaper requests; lower latency).
  receive_wait_time_seconds = 20
  message_retention_seconds = 345600 # 4 days
  # SSE-SQS, not SSE-KMS: S3 can't send to a queue encrypted with the
  # AWS-managed aws/sqs KMS key.
  sqs_managed_sse_enabled = true

  # After 10 receives without a delete, park the message in the DLQ so a
  # message no worker can handle (malformed, never claimed) can't loop
  # forever. Not the job retry limit: the worker gives a job up after 3 real
  # attempts (max_attempts, counted on the job item), because SQS also counts
  # harmless receives (released during scale-in, handed back on SIGTERM).
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 10
  })
}

# Only the main queue may use the DLQ. A separate resource avoids a cycle
# (jobs -> dlq ARN for redrive, dlq -> jobs ARN for this policy).
resource "aws_sqs_queue_redrive_allow_policy" "jobs_dlq" {
  queue_url = aws_sqs_queue.jobs_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.jobs.arn]
  })
}

# Let S3 send events to the queue, but only from our media bucket in our
# account (prevents the confused-deputy problem).
data "aws_iam_policy_document" "jobs_queue" {
  statement {
    sid       = "AllowMediaBucketEvents"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.media.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "jobs" {
  queue_url = aws_sqs_queue.jobs.id
  policy    = data.aws_iam_policy_document.jobs_queue.json
}

# New objects under raw/ -> job queue. This resource owns the bucket's entire
# notification configuration (a bucket has only one).
#
# On create/update S3 validates the destination by sending an s3:TestEvent
# message (no "Records" key). The worker must recognise and delete it.
resource "aws_s3_bucket_notification" "media" {
  bucket = aws_s3_bucket.media.id

  queue {
    queue_arn     = aws_sqs_queue.jobs.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
  }

  # S3's validation send fails unless the queue policy already exists; the
  # queue ARN reference alone doesn't make Terraform wait for the policy.
  depends_on = [aws_sqs_queue_policy.jobs]
}
