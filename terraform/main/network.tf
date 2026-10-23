# Network: one VPC, two public subnets, no NAT, no interface endpoints.
#
# Tasks run in public subnets with public IPs so they can reach ECR, SQS,
# Polly, CloudWatch Logs and STS through the internet gateway. Security groups
# (security.tf) control what may come in. S3 and DynamoDB traffic uses free
# gateway endpoints instead of the internet.
#
# Production would put tasks in private subnets without public IPs and add a
# NAT gateway or interface endpoints, at a real monthly cost.

locals {
  azs = ["ap-south-1a", "ap-south-1b"]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_subnet" "public" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value) # 10.20.0.0/24, 10.20.1.0/24
  # Public IPs are requested per ECS service (assign_public_ip), not for
  # everything launched here.
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${each.key}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Gateway endpoints are free: S3 (including ECR image layers) and DynamoDB
# traffic stays on the AWS network. IAM policies still decide what's allowed.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-south-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = { Name = "${local.name}-s3" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-south-1.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = { Name = "${local.name}-dynamodb" }
}

# Every VPC gets a default security group that allows all traffic between its
# members. Remove its rules so nothing can silently rely on it.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-default-locked" }
}
