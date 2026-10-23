variable "allowed_origins" {
  description = "Browser origins allowed to PUT/GET media via presigned URLs (S3 CORS)."
  type        = list(string)
  default     = ["http://localhost:5173"] # Vite dev server (Phase 6)

  validation {
    # The browser's Origin header is scheme://host[:port] with no path or
    # trailing slash; anything else silently never matches.
    condition     = alltrue([for o in var.allowed_origins : can(regex("^https?://[^/]+$", o))])
    error_message = "Each origin must look like http(s)://host[:port] with no path or trailing slash."
  }
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the ALB on port 80 (e.g. home IP /32, dev box public IP /32). Set in terraform.tfvars."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_cidrs must be a non-empty list of valid CIDRs, e.g. [\"203.0.113.7/32\"]."
  }

  # The API has no authentication yet: anyone could upload 200 MB videos and
  # spend Fargate and Polly time. Remove this check deliberately when ready.
  validation {
    condition     = !anytrue([for c in var.allowed_cidrs : contains(["0.0.0.0/0", "::/0"], c)])
    error_message = "allowed_cidrs must not open the ALB to the whole internet (0.0.0.0/0 or ::/0) until the API has authentication."
  }
}

variable "enable_compute" {
  description = "Create the ALB, target group, listener and ECS services. Set false to pause (network, ECR, IAM, logs, cluster and task definitions stay)."
  type        = bool
  default     = true
}

variable "api_image_tag" {
  description = "Tag of the reelops-api image in ECR (git short SHA). Written to images.auto.tfvars by scripts/push_images.sh."
  type        = string

  validation {
    condition     = var.api_image_tag != "latest" && can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.api_image_tag))
    error_message = "api_image_tag must be a specific image tag (e.g. a git SHA), never \"latest\"."
  }
}

variable "worker_image_tag" {
  description = "Tag of the reelops-worker image in ECR (git short SHA). Written to images.auto.tfvars by scripts/push_images.sh."
  type        = string

  validation {
    condition     = var.worker_image_tag != "latest" && can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.worker_image_tag))
    error_message = "worker_image_tag must be a specific image tag (e.g. a git SHA), never \"latest\"."
  }
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic. Set in terraform.tfvars (git-ignored) or TF_VAR_alert_email in CI."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}
