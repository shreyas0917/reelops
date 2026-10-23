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
