# syntax=docker/dockerfile:1
#
# ReelOps API image. Same layout as the worker: deps -> test -> runtime.
#
#   docker build -t reelops-api app/                     # production image
#   docker build -t reelops-api:test --target test app/

# ---- deps --------------------------------------------------------------------
FROM python:3.12-slim@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704 AS deps

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin app

# Requirements before code: this layer is reused until a pin changes.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && pip check

WORKDIR /app

# ---- test: deps + pytest/moto + tests (never shipped) --------------------------
FROM deps AS test
COPY requirements-dev.txt /tmp/requirements-dev.txt
RUN pip install --no-cache-dir -r /tmp/requirements-dev.txt && pip check
COPY reelops_api/ ./reelops_api/
COPY tests/ ./tests/
USER app
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider"]

# ---- runtime: deps + app code (last stage = default build target) ------------
FROM deps AS runtime
COPY reelops_api/ ./reelops_api/
USER app
EXPOSE 8000
# 0.0.0.0: reachable from outside the container. Exec form: uvicorn gets
# SIGTERM directly and drains in-flight requests.
CMD ["uvicorn", "--factory", "reelops_api.main:create_app", "--host", "0.0.0.0", "--port", "8000"]
