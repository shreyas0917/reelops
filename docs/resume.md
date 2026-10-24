# ReelOps: resume bullets

Each bullet uses a number from the [README](../README.md#results), with a
one-line proof pointing at the document that backs it.

- **Built a queue-driven video pipeline on AWS ECS Fargate that turns a 2-minute
  narrated screen recording into a captioned, AI-voiced demo in ~33 s on a
  single 2-vCPU worker** (Whisper, Amazon Polly, FFmpeg), with workers
  autoscaling 0 → 3 → 0 on queue depth.
  - *Proof:* [learning notes, "Task 5 — Processing time"](learning-notes.md)
    (worker pipeline time on a running worker; excludes upload and queue wait)
    and the Phase 5 load test.

- **Provisioned the whole stack with Terraform: 70+ managed resources** (ECS
  Fargate, ALB, S3, SQS with a dead-letter queue, DynamoDB, CloudWatch, SNS,
  least-privilege IAM) in one region with no NAT gateway and a one-variable
  pause switch (~$0.05/hour idle).
  - *Proof:* [README, Results](../README.md#results) (77 resources from
    `terraform state list`: 70 + 7 bootstrap) and [Cost](../README.md#cost).

- **Shipped it through GitHub Actions with no stored AWS keys:** OIDC sign-in,
  gitleaks, Trivy image scanning, a Terraform plan posted on every PR, and
  human-approved deploys from `main`.
  - *Proof:* [README, CI/CD and security](../README.md#cicd-and-security)
    and the workflows in [`.github/workflows/`](../.github/workflows/).

- **Ran 8 failure drills against the live stack** (worker stop and crash,
  duplicate events, poison input, DLQ alerting, API replacement, scale-in
  protection, give-up alarm) **and found and fixed 5 bugs**, each fix backed by
  a test or a re-run drill.
  - *Proof:* [failure tests](failure-tests.md) (summary table and evidence)
    and [README, Bugs found and fixed](../README.md#bugs-found-and-fixed).
