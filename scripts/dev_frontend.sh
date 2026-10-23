#!/usr/bin/env bash
# Vite dev server with hot reload on http://localhost:5173. /jobs and /healthz
# are proxied (frontend/vite.config.ts) to the docker compose API on :8000,
# which uses the real AWS resources.
#
# Needs the API: docker compose up -d --build --wait
# From Windows: VS Code -> Ports panel -> Forward a Port -> 5173, then open
# http://localhost:5173 (it must stay 5173: the bucket's CORS allows exactly
# that origin).
# Usage: scripts/dev_frontend.sh            (Ctrl-C to stop)
set -euo pipefail

cd "$(dirname "$0")/../frontend"
NODE="node:24.22.1-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205"

if ! curl -sf -m 3 http://127.0.0.1:8000/healthz >/dev/null; then
  echo "note: the API isn't answering on :8000; start it with: docker compose up -d --build --wait" >&2
fi
[ -d node_modules ] || echo "note: installing dependencies first (npm ci)" >&2

TTY=()
# -it only when both stdin and stdout are terminals (not when backgrounded)
[ -t 0 ] && [ -t 1 ] && TTY=(-it)
# --network host: inside the container, localhost:8000 is the compose API.
# Vite binds 127.0.0.1 only (see package.json), so nothing is exposed publicly.
# --init: tini as PID 1 forwards Ctrl-C / docker stop to Vite (sh as PID 1
# doesn't, so it would be SIGKILLed after the timeout).
exec docker run --rm --init "${TTY[@]}" --name reelops-frontend-dev --network host \
  -v "$PWD:/app" -w /app --user "$(id -u):$(id -g)" -e HOME=/tmp \
  "$NODE" sh -c '[ -d node_modules ] || npm ci; npm run dev'
