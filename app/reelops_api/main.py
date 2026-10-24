"""HTTP layer: request/response models, routes, error mapping.

Run with: uvicorn --factory reelops_api.main:create_app
"""

from __future__ import annotations

from pathlib import Path
from uuid import UUID

import boto3
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from . import __version__
from .config import Settings
from .jobs import InvalidUpload, JobNotFound, create_job, get_job, make_s3_client
from .static import SpaStaticFiles


class CreateJobRequest(BaseModel):
    filename: str = Field(min_length=1, max_length=255)
    content_type: str
    size: int = Field(gt=0, description="file size in bytes")


class CreateJobResponse(BaseModel):
    job_id: str
    upload_url: str
    upload_method: str
    upload_headers: dict[str, str]
    expires_in: int


class Segment(BaseModel):
    start: float = Field(description="seconds from the start of the video")
    end: float
    text: str


class JobResponse(BaseModel):
    job_id: str
    status: str
    filename: str | None = Field(description="the uploaded file's name, sanitized; null for older jobs")
    error: str | None
    attempts: int
    created_at: int
    updated_at: int
    download_url: str | None
    preview_url: str | None
    original_preview_url: str | None = Field(description="the raw upload, playable inline; once done")
    segments: list[Segment] = Field(description="burned-in captions in order; empty until done")
    voice: str | None = Field(description="Polly voice used; once done")


def create_app(settings: Settings | None = None, *, s3=None, table=None) -> FastAPI:
    """Build the app. Tests pass their own settings and (moto) clients."""
    settings = settings or Settings.from_env()
    s3 = s3 or make_s3_client(settings.aws_region)
    table = table or boto3.resource("dynamodb", region_name=settings.aws_region).Table(settings.jobs_table)

    app = FastAPI(title="ReelOps API", version=__version__)

    # Liveness only: no AWS calls, so a DynamoDB blip doesn't make the load
    # balancer kill every API task at once.
    @app.get("/healthz")
    def healthz() -> dict:
        return {"status": "ok"}

    # Plain "def" (not async): boto3 blocks, and FastAPI runs sync routes in a
    # thread pool instead of on the event loop.
    @app.post("/jobs", status_code=201, response_model=CreateJobResponse)
    def post_job(req: CreateJobRequest) -> dict:
        try:
            return create_job(req.filename, req.content_type, req.size, settings=settings, table=table, s3=s3)
        except InvalidUpload as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from None

    @app.get("/jobs/{job_id}", response_model=JobResponse)
    def read_job(job_id: UUID) -> dict:
        try:
            return get_job(str(job_id), settings=settings, table=table, s3=s3)
        except JobNotFound:
            raise HTTPException(status_code=404, detail="job not found") from None

    # The web UI, from the same origin as the API. Mounted last: Starlette
    # matches in order, so /jobs and /healthz always reach the routes above.
    if settings.static_dir and Path(settings.static_dir, "index.html").is_file():
        app.mount("/", SpaStaticFiles(directory=settings.static_dir, html=True), name="ui")

    return app
