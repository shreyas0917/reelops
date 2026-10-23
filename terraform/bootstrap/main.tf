# Look up the account ID at plan time so it is never hardcoded in the repo.
data "aws_caller_identity" "current" {}

# S3 bucket names are global, so the account ID suffix keeps ours unique.
resource "aws_s3_bucket" "tfstate" {
  bucket = "reelops-tfstate-${data.aws_caller_identity.current.account_id}"

  # Losing this bucket means losing all Terraform state. Terraform will refuse
  # any plan that would delete it.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning keeps every previous state file, so a bad apply or a corrupted
# state can be rolled back.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256): encrypted at rest with S3-managed keys, at no extra cost.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State must never be public.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny any request not made over HTTPS. The "*" principal/action is safe here
# because this is a Deny statement: it removes access, it never grants it.
data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json

  # Apply the public access block first; S3 can reject policy changes that
  # race with it.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}
