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

variable "enable_compute" {
  description = "Create the ALB, target group, listener and ECS services. Set false to pause (network, ECR, IAM, logs, cluster and task definitions stay)."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic. Set in terraform.tfvars (git-ignored) or TF_VAR_alert_email in CI."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}
