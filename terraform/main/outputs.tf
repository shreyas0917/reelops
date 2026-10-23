# Values for verification commands and, in Phase 3, the worker's environment.
# Several contain the account ID: print them, don't commit them.

output "media_bucket_name" {
  description = "S3 bucket for uploads (raw/) and results (output/)"
  value       = aws_s3_bucket.media.bucket
}

output "jobs_queue_url" {
  description = "URL of the main job queue (used by SQS API calls)"
  value       = aws_sqs_queue.jobs.url
}

output "jobs_queue_arn" {
  description = "ARN of the main job queue (used in IAM policies)"
  value       = aws_sqs_queue.jobs.arn
}

output "jobs_dlq_url" {
  description = "URL of the dead-letter queue"
  value       = aws_sqs_queue.jobs_dlq.url
}

output "jobs_table_name" {
  description = "DynamoDB table holding job status"
  value       = aws_dynamodb_table.jobs.name
}

output "alerts_topic_arn" {
  description = "SNS topic for alarm notifications"
  value       = aws_sns_topic.alerts.arn
}

output "ecr_repository_urls" {
  description = "ECR repository URLs by image (used by scripts/push_images.sh)"
  value       = { for k, repo in aws_ecr_repository.this : k => repo.repository_url }
}
