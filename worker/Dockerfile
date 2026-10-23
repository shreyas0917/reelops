# syntax=docker/dockerfile:1
#
# ReelOps worker image. Layers are ordered from least to most frequently
# changed so that a code edit only rebuilds the final COPY.
#
#   docker build -t reelops-worker worker/                  # production image
#   docker build -t reelops-worker:test --target test worker/

# ---- deps: system packages, Python packages and the Whisper model ----------
FROM python:3.12-slim@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704 AS deps

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

# ffmpeg for media work, DejaVu for burned-in captions. One RUN so the apt
# lists are deleted in the same layer they were created in.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin app

# Requirements before code: this layer is reused until a pin changes.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Bake the model into the image (root-owned, read-only to the app user) and
# run offline so jobs never depend on huggingface.co at runtime.
ARG WHISPER_MODEL=base
ENV REELOPS_WHISPER_MODEL=${WHISPER_MODEL} \
    REELOPS_WHISPER_MODEL_DIR=/opt/models
# chmod: the Hugging Face cache writes some metadata files as owner-only.
RUN python -c "from faster_whisper import WhisperModel; \
WhisperModel('${WHISPER_MODEL}', device='cpu', compute_type='int8', download_root='/opt/models')" \
    && chmod -R a+rX /opt/models
ENV HF_HUB_OFFLINE=1

WORKDIR /app

# ---- test: deps + pytest + tests (never shipped) ---------------------------
FROM deps AS test
COPY requirements-dev.txt /tmp/requirements-dev.txt
RUN pip install --no-cache-dir -r /tmp/requirements-dev.txt
COPY reelops_worker/ ./reelops_worker/
COPY tests/ ./tests/
USER 10001:10001
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider"]

# ---- runtime: deps + app code (last stage = default build target) ----------
FROM deps AS runtime
COPY reelops_worker/ ./reelops_worker/
USER 10001:10001
ENTRYPOINT ["python", "-m", "reelops_worker"]
