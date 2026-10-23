output "state_bucket_name" {
  description = "S3 bucket for Terraform remote state (used by terraform/main backend)"
  value       = aws_s3_bucket.tfstate.bucket
}
