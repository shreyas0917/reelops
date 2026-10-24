# GitHub Actions -> AWS with OIDC: no long-lived keys anywhere.
#
# A workflow job with `permissions: id-token: write` gets a short-lived JWT
# signed by GitHub. Its claims say who is asking (aud = sts.amazonaws.com,
# sub = repo:<owner>@<owner-id>/<repo>@<repo-id>:<context>; this repo uses
# GitHub's immutable subject format). The job exchanges it with
# sts:AssumeRoleWithWebIdentity; AWS verifies the signature and the trust
# policy's aud/sub conditions and returns ~1-hour credentials for that role.
#
# These resources are managed locally only: the deploy role is denied any
# change to them (it can't widen its own trust or permissions).

variable "github_repo" {
  description = "GitHub repository allowed to assume the CI roles (owner/repo)."
  type        = string
  default     = "shreyas0917/reelops"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/repo."
  }
}

# GitHub's immutable subject format includes numeric IDs, which are never
# reused: a deleted-and-recreated repo or a re-registered owner name can't
# match these roles ("repo-jacking"). Public metadata, not secrets:
#   gh api repos/<owner>/<repo> --jq '.owner.id, .id'
variable "github_owner_id" {
  description = "Numeric GitHub user/org ID of the repository owner."
  type        = number
  default     = 150114060
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID."
  type        = number
  default     = 1430851219
}

locals {
  gh_issuer = "token.actions.githubusercontent.com"
  # e.g. repo:shreyas0917@150114060/reelops@1430851219
  gh_sub_prefix  = "repo:${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"
  tfstate_bucket = "reelops-tfstate-${local.account_id}" # created by terraform/bootstrap
}

# AWS validates GitHub's certificate via trusted root CAs; no thumbprint pin.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.gh_issuer}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---- reelops-gha-plan: pull requests (and branch refs), read-only + state lock --

data "aws_iam_policy_document" "gha_plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.gh_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.gh_issuer}:sub"
      values = [
        "${local.gh_sub_prefix}:pull_request",
        "${local.gh_sub_prefix}:ref:refs/heads/*",
      ]
    }
  }
}

resource "aws_iam_role" "gha_plan" {
  name               = "reelops-gha-plan"
  description        = "GitHub Actions: terraform plan on pull requests (read-only + state lock)"
  assume_role_policy = data.aws_iam_policy_document.gha_plan_trust.json
}

# Broad on purpose: plan must describe every resource type. Note it includes
# data reads (e.g. s3:GetObject on all buckets); the tighter ViewOnlyAccess +
# hand-picked reads breaks refresh whenever a new resource type is added.
resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# With use_lockfile, plan takes the state lock (writes, then deletes
# main.tfstate.tflock) so it reads a consistent state while no apply runs.
data "aws_iam_policy_document" "gha_plan" {
  statement {
    sid       = "StateLockOnly"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.tfstate_bucket}/reelops/main.tfstate.tflock"]
  }
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.tfstate_bucket}/reelops/main.tfstate"]
  }
}

resource "aws_iam_role_policy" "gha_plan" {
  name   = "state-lock"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.gha_plan.json
}

# ---- reelops-gha-deploy: only the protected "production" environment ------------

data "aws_iam_policy_document" "gha_deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.gh_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.gh_issuer}:sub"
      values   = ["${local.gh_sub_prefix}:environment:production"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "reelops-gha-deploy"
  description        = "GitHub Actions: image push + terraform apply, production environment only"
  assume_role_policy = data.aws_iam_policy_document.gha_deploy_trust.json
}

# Reads for refresh (Describe*/List*/Get* across services).
resource "aws_iam_role_policy_attachment" "gha_deploy_readonly" {
  role       = aws_iam_role.gha_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "gha_deploy" {
  statement {
    sid     = "TerraformState"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${local.tfstate_bucket}/reelops/*",
    ]
  }

  statement {
    sid       = "MediaBucket"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.media.arn, "${aws_s3_bucket.media.arn}/*"]
  }

  statement {
    sid     = "DataServices"
    actions = ["sqs:*", "dynamodb:*", "sns:*"]
    resources = [
      "arn:aws:sqs:ap-south-1:${local.account_id}:reelops-*",
      "arn:aws:dynamodb:ap-south-1:${local.account_id}:table/reelops-*",
      "arn:aws:sns:ap-south-1:${local.account_id}:reelops-*",
    ]
  }

  statement {
    sid = "AlarmsAndDashboards"
    actions = [
      "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource",
      "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards",
    ]
    resources = [
      "arn:aws:cloudwatch:ap-south-1:${local.account_id}:alarm:reelops-*",
      "arn:aws:cloudwatch::${local.account_id}:dashboard/reelops-*",
    ]
  }

  statement {
    sid = "LogGroups"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
      "logs:TagResource", "logs:UntagResource", "logs:TagLogGroup", "logs:UntagLogGroup",
      # Metric filters on these log groups (alarms.tf: worker_gave_up).
      "logs:PutMetricFilter", "logs:DeleteMetricFilter",
    ]
    resources = ["arn:aws:logs:ap-south-1:${local.account_id}:log-group:/reelops/*"]
  }

  statement {
    sid       = "EcrRepositories"
    actions   = ["ecr:*"]
    resources = ["arn:aws:ecr:ap-south-1:${local.account_id}:repository/reelops-*"]
  }

  # GetAuthorizationToken has no resource; it only returns a registry login.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid     = "EcsResources"
    actions = ["ecs:*"]
    resources = [
      "arn:aws:ecs:ap-south-1:${local.account_id}:cluster/reelops-*",
      "arn:aws:ecs:ap-south-1:${local.account_id}:service/reelops-*/*",
      "arn:aws:ecs:ap-south-1:${local.account_id}:task-definition/reelops-*:*",
    ]
  }

  # ECS doesn't support resource-level permissions for these.
  statement {
    sid       = "EcsTaskDefinitions"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-south-1"]
    }
  }

  statement {
    sid     = "LoadBalancer"
    actions = ["elasticloadbalancing:*"]
    resources = [
      "arn:aws:elasticloadbalancing:ap-south-1:${local.account_id}:loadbalancer/app/reelops-*/*",
      "arn:aws:elasticloadbalancing:ap-south-1:${local.account_id}:targetgroup/reelops-*/*",
      "arn:aws:elasticloadbalancing:ap-south-1:${local.account_id}:listener/app/reelops-*/*",
      "arn:aws:elasticloadbalancing:ap-south-1:${local.account_id}:listener-rule/app/reelops-*/*",
    ]
  }

  # EC2 resources are named by generated IDs, so no name pattern is possible:
  # an explicit list of networking actions, ap-south-1 only. (No instances.)
  statement {
    sid = "Networking"
    actions = [
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway", "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
      "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:ModifyVpcEndpoint",
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress", "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-south-1"]
    }
  }

  # Scalable-target ARNs are generated IDs; ap-south-1 only.
  statement {
    sid = "Autoscaling"
    actions = [
      "application-autoscaling:RegisterScalableTarget", "application-autoscaling:DeregisterScalableTarget",
      "application-autoscaling:PutScalingPolicy", "application-autoscaling:DeleteScalingPolicy",
      "application-autoscaling:TagResource", "application-autoscaling:UntagResource",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-south-1"]
    }
  }

  statement {
    sid       = "AutoscalingServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.application-autoscaling.amazonaws.com"]
    }
  }

  # The ECS execution and task roles (reelops-dev-*) only.
  statement {
    sid = "EcsRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/reelops-dev-*"]
  }

  statement {
    sid       = "EcsRolesManagedPolicy"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/reelops-dev-*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
    }
  }

  statement {
    sid       = "PassEcsRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/reelops-dev-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # ---- guardrails: explicit denies win over any allow ----

  statement {
    sid    = "NoUsersOrKeys"
    effect = "Deny"
    actions = [
      "iam:CreateUser", "iam:CreateAccessKey", "iam:UpdateAccessKey", "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile", "iam:AttachUserPolicy", "iam:PutUserPolicy", "iam:AddUserToGroup",
    ]
    resources = ["*"]
  }

  # CI can't widen its own trust or permissions; these are applied locally.
  statement {
    sid    = "NoChangesToCiAccess"
    effect = "Deny"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary", "iam:TagRole", "iam:UntagRole",
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/reelops-gha-*",
      "arn:aws:iam::${local.account_id}:oidc-provider/${local.gh_issuer}",
    ]
  }

  # The state bucket's configuration belongs to terraform/bootstrap.
  statement {
    sid    = "ProtectStateBucket"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration", "s3:PutEncryptionConfiguration", "s3:PutBucketPublicAccessBlock",
      "s3:DeleteObjectVersion",
    ]
    resources = ["arn:aws:s3:::${local.tfstate_bucket}", "arn:aws:s3:::${local.tfstate_bucket}/*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy" {
  name   = "deploy"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy.json
}

output "gha_plan_role_arn" {
  description = "Role for the terraform plan workflow (pull requests)"
  value       = aws_iam_role.gha_plan.arn
}

output "gha_deploy_role_arn" {
  description = "Role for the deploy job (production environment)"
  value       = aws_iam_role.gha_deploy.arn
}
