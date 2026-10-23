# Security groups. Each group is created empty (Terraform removes AWS's default
# allow-all egress) and every rule is a separate resource.
#
# Outbound 443 to 0.0.0.0/0: on Fargate the ECS agent's traffic (ECR pulls,
# CloudWatch Logs) uses the task's ENI, and SQS/Polly are public endpoints on
# large, changing IP ranges. S3 and DynamoDB also use 443 via the gateway
# endpoints. DNS, the ECS credentials endpoint (169.254.170.2) and time sync
# aren't filtered by security groups, so they need no rule.

# ---- ALB ----------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ReelOps ALB: HTTP from allowed CIDRs only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-alb" }
}

# Not 0.0.0.0/0: the API has no authentication yet (see var.allowed_cidrs).
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.key}"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.key
}

# The ALB only talks to its targets (traffic and health checks).
resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To API tasks"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.api.id
}

# ---- API tasks ------------------------------------------------------------------

resource "aws_security_group" "api" {
  name        = "${local.name}-api"
  description = "ReelOps API tasks: 8000 from the ALB only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-api" }
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  description                  = "From the ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "api_https" {
  security_group_id = aws_security_group.api.id
  description       = "HTTPS to AWS APIs (ECR, Logs, DynamoDB/S3 via endpoints)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- worker tasks ---------------------------------------------------------------

# No ingress rules at all: the worker only makes outbound calls.
resource "aws_security_group" "worker" {
  name        = "${local.name}-worker"
  description = "ReelOps worker tasks: no inbound"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-worker" }
}

resource "aws_vpc_security_group_egress_rule" "worker_https" {
  security_group_id = aws_security_group.worker.id
  description       = "HTTPS to AWS APIs (ECR, Logs, SQS, Polly, S3/DynamoDB via endpoints)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
