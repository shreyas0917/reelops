# Remote state in the S3 bucket created by terraform/bootstrap.
#
# Partial configuration: "bucket" is intentionally omitted because the name
# contains the AWS account ID, which must not be committed. Supply it at init:
#
#   terraform init -backend-config="bucket=reelops-tfstate-$(aws sts get-caller-identity --query Account --output text)"
terraform {
  backend "s3" {
    key          = "reelops/main.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true # native S3 locking (.tflock object); no DynamoDB table needed
  }
}
