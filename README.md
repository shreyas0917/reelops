# ReelOps

Turn a screen recording into a captioned, AI-voiced demo video.

**Stack:** Python 3.12 · FastAPI · faster-whisper · Amazon Polly · ffmpeg · Docker ·
Terraform · AWS ECS Fargate · S3 · SQS · DynamoDB · GitHub Actions — region `ap-south-1`.

## Status

Phase 0 — project setup (tooling, repo skeleton, Terraform remote state). No app code yet.

## Layout

| Path | Purpose |
|---|---|
| `app/` | FastAPI API |
| `worker/` | Transcription, voice-over and ffmpeg rendering |
| `frontend/` | Web UI |
| `terraform/bootstrap/` | One-time: Terraform state bucket (local state) |
| `terraform/main/` | All other infrastructure (remote state in S3) |
| `.github/workflows/` | CI/CD |
| `docs/` | Notes and diagrams |
| `samples/` | Sample inputs; `samples/output/` is git-ignored |
