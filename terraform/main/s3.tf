# Media bucket: uploads land in raw/, finished videos go to output/.

resource "aws_s3_bucket" "media" {
  # Bucket names are global; the account ID keeps ours unique.
  bucket = "reelops-media-${local.account_id}"
}

# Disable ACLs entirely: access is controlled by policies only.
resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Deny any request not made over HTTPS. The "*" principal/action is safe
# because this is a Deny: it removes access, it never grants it.
data "aws_iam_policy_document" "media_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.media.arn,
      "${aws_s3_bucket.media.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "media" {
  bucket     = aws_s3_bucket.media.id
  policy     = data.aws_iam_policy_document.media_tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.media]
}

# Keep storage near zero without a cleanup job. Expiry runs asynchronously
# (usually within a day of the deadline).
resource "aws_s3_bucket_lifecycle_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    id     = "expire-raw"
    status = "Enabled"
    filter {
      prefix = "raw/"
    }
    expiration {
      days = 3
    }
  }

  rule {
    id     = "expire-output"
    status = "Enabled"
    filter {
      prefix = "output/"
    }
    expiration {
      days = 14
    }
  }

  # Parts of abandoned multipart uploads are invisible in listings but billed.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Lets browser JavaScript on allowed origins PUT/GET with presigned URLs.
# CORS is browser-enforced; authorization is still the presigned URL's
# signature, and the bucket stays private. The UI is served by the API behind
# the ALB, so the ALB's own origin is added while compute runs; it follows the
# ALB's new DNS name across pause/resume.
locals {
  cors_origins = concat(
    var.allowed_origins,
    var.enable_compute ? ["http://${aws_lb.api[0].dns_name}"] : [],
  )
}

resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_methods = ["PUT", "GET"]
    allowed_origins = local.cors_origins
    # What a presigned PUT sends, including SDK checksum headers.
    allowed_headers = ["content-type", "x-amz-*"]
    # Readable by browser JS; needed for multipart uploads.
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
