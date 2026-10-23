# CLAUDE.md — ReelOps working rules

ReelOps turns a screen recording into a captioned, AI-voiced demo video.
This is a learning/portfolio DevOps project.

## Environment

- Dev box: EC2 `reelops-devbox`, Ubuntu 26.04 (x86_64), region ap-south-1.
- System Python on the dev box is 3.14. App containers use `python:3.12-slim`;
  the project targets Python 3.12 regardless of the host version.
- The dev box itself (EC2 `reelops-devbox` and its IAM role `reelops-devbox-role`)
  was created by hand and is NOT managed by this repo's Terraform.

## How to work with me

- I am learning: explain what and why before writing code or creating a file.
- Work in small steps. After each step, give me a command to verify it worked.

## Terraform

- Never run `terraform apply` or `terraform destroy` yourself. Run `plan`,
  explain it, and let me run apply.
- `terraform/bootstrap/` holds only the state bucket and uses local state.
  `terraform/main/` uses the S3 backend.

## AWS

- Region is always `ap-south-1`.
- Every AWS resource gets tags: `Project=reelops`, `Env=dev`, `ManagedBy=terraform`.
- Never write AWS keys, secrets or account IDs into files. Look up the account
  ID with a data source. Credentials come from the EC2 instance role locally and
  from GitHub OIDC in CI. Never run `aws configure` or create access keys.
- Least-privilege IAM: no `"*"` actions or resources in app roles unless
  explained and unavoidable.
- Keep cost near zero: no NAT gateways, no interface VPC endpoints.
