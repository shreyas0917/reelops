# ReelOps: resume bullets

Each bullet uses a number from the [README](../README.md#results), with a
one-line proof pointing at the document that backs it.

1. Processed 2-minute screen recordings into captioned, AI-voiced videos in
   ~33 seconds per job by building an event-driven pipeline using S3, SQS,
   ECS Fargate, Whisper, Amazon Polly, and FFmpeg.
   - *Proof:* [learning notes, "Task 5 — Processing time"](learning-notes.md)
     (worker pipeline time on a running worker; excludes upload and queue wait)
     and [README, How it works](../README.md#how-it-works).

2. Achieved $0 idle worker compute cost and processed 8 concurrent jobs with
   zero failures by provisioning 70+ AWS resources using Terraform and
   implementing SQS-driven autoscaling from 0 to 3 workers.
   - *Proof:* [learning notes, Phase 5 load test](learning-notes.md) ("all 8
     done on the first attempt, 0 failed"; workers back to 0 when idle) and
     [README, Results](../README.md#results) (77 resources from
     `terraform state list`: 70 + 7 bootstrap).

3. Eliminated stored AWS credentials and automated secure deployments by
   implementing GitHub Actions CI/CD with OIDC, Gitleaks, Trivy, Terraform
   plan reviews, and approval-gated ECS rolling updates.
   - *Proof:* [README, CI/CD and security](../README.md#cicd-and-security)
     and the workflows in [`.github/workflows/`](../.github/workflows/).

4. Found and fixed 5 reliability and security bugs through 8 failure-injection
   drills and Terraform plan reviews, hardening a fault-tolerant design with
   DynamoDB lease-based job claiming, heartbeats, dead-letter queues, SNS
   alerts, and graceful SIGTERM shutdown.
   - *Proof:* [failure tests](failure-tests.md) (summary table and evidence),
     [README, Bugs found and fixed](../README.md#bugs-found-and-fixed) and
     [README, How it works](../README.md#how-it-works).
