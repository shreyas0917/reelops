# Public ALB in front of the API. Created only when var.enable_compute is
# true (the nightly pause removes it).
#
# Production upgrade: HTTPS on 443 with an ACM certificate for a real domain
# (DNS-validated), a modern TLS policy, 80 -> 443 redirect, and WAF.

locals {
  compute = var.enable_compute ? 1 : 0
}

resource "aws_lb" "api" {
  count = local.compute

  name               = "${local.name}-api"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]
  # Drop malformed headers instead of forwarding them to the app.
  drop_invalid_header_fields = true
  # Dev: no deletion protection (the pause deletes it), no access logs (cost).
  enable_deletion_protection = false
}

# Fargate tasks register by IP (awsvpc), not by instance.
resource "aws_lb_target_group" "api" {
  count = local.compute

  name        = "${local.name}-api"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  protocol    = "HTTP"
  port        = 8000
  # Requests take milliseconds; the 300 s default would slow every deploy.
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  count = local.compute

  load_balancer_arn = aws_lb.api[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[0].arn
  }
}
