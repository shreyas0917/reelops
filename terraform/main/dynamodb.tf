# Jobs table: one item per video job, used by the worker (Phase 3) and the
# API (Phase 6).
#
# Item shape (all timestamps are epoch seconds, type N):
#   job_id      S  partition key; chosen at upload, S3 key is raw/<job_id>/<filename>
#   status      S  pending | processing | done | failed
#   s3_key      S  uploaded object key (raw/...)
#   etag        S  identifies the uploaded content; detects duplicate S3 events
#   claimed_at  N  lease start: when the current worker claimed the job
#   attempts    N  incremented on every claim
#   error       S  last failure message
#   created_at  N
#   updated_at  N
#   expires_at  N  TTL: DynamoDB deletes the item some time after this
#
# Lease: a worker claims a job with a conditional write that succeeds only if
# status = pending, or status = processing and claimed_at is older than the
# lease (= SQS visibility timeout, 300 s). A killed worker's claim expires, so
# the redelivered message can take over instead of the job staying
# "processing" forever, and two live workers can't process the same job.
resource "aws_dynamodb_table" "jobs" {
  name         = "${local.name}-jobs"
  billing_mode = "PAY_PER_REQUEST" # no capacity planning, nothing to pay when idle
  hash_key     = "job_id"

  # Only key attributes are declared; DynamoDB is schemaless otherwise.
  attribute {
    name = "job_id"
    type = "S"
  }

  # Deletion is lazy (typically within a day or two of expires_at), so readers
  # should treat expired items as gone.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # No server_side_encryption block: encrypted at rest with an AWS-owned key
  # (the free default). Point-in-time recovery and deletion protection are
  # left off for dev to keep cost near zero; enable both for prod.
}
