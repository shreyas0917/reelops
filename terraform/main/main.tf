# Shared lookups and naming used across the other files.

# Account ID at plan time, so it is never hardcoded in the repo.
data "aws_caller_identity" "current" {}

locals {
  name       = "reelops-dev" # prefix for resource names
  account_id = data.aws_caller_identity.current.account_id
}
