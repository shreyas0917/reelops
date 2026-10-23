terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Credentials come from the EC2 instance role (locally) or GitHub OIDC (CI).
provider "aws" {
  region = "ap-south-1"

  default_tags {
    tags = {
      Project   = "reelops"
      Env       = "dev"
      ManagedBy = "terraform"
    }
  }
}
