# syntax=docker/dockerfile:1
#
# ReelOps API image: the FastAPI service plus the built web UI.
# Build context is the repo root (it needs app/ and frontend/):
#
#   docker build -f app/Dockerfile -t reelops-api .                  # production
#   docker build -f app/Dockerfile -t reelops-api:test --target test .

# ---- frontend: build the UI; only dist/ reaches the final image -------------
FROM node:24.22.1-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205 AS frontend
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
WORKDIR /fe
# Dependencies before sources: reused until the lock file changes.
COPY frontend/package.json frontend/package-lock.json frontend/.npmrc ./
RUN npm ci
COPY frontend/index.html frontend/tsconfig.json frontend/vite.config.ts ./
COPY frontend/public/ ./public/
COPY frontend/src/ ./src/
# Unit tests and the type-check gate the build.
RUN npm test && npm run build

# ---- deps --------------------------------------------------------------------
FROM python:3.12-slim@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704 AS deps

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin app

# Requirements before code: this layer is reused until a pin changes.
COPY app/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && pip check

WORKDIR /app

# ---- test: deps + pytest/moto + tests (never shipped) --------------------------
FROM deps AS test
COPY app/requirements-dev.txt /tmp/requirements-dev.txt
RUN pip install --no-cache-dir -r /tmp/requirements-dev.txt && pip check
COPY app/reelops_api/ ./reelops_api/
COPY app/tests/ ./tests/
USER 10001:10001
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider"]

# ---- runtime: deps + app code (last stage = default build target) ------------
FROM deps AS runtime
COPY app/reelops_api/ ./reelops_api/
COPY --from=frontend /fe/dist/ ./static/
ENV REELOPS_STATIC_DIR=/app/static
USER 10001:10001
EXPOSE 8000
# 0.0.0.0: reachable from outside the container. Exec form: uvicorn gets
# SIGTERM directly and drains in-flight requests.
CMD ["uvicorn", "--factory", "reelops_api.main:create_app", "--host", "0.0.0.0", "--port", "8000"]
