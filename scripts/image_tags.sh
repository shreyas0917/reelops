#!/usr/bin/env bash
# The single place that decides image tags (used by Terraform's
# data "external" "image_tags", push_images.sh and CI):
#   api    = last commit touching what goes into the API image
#   worker = last commit touching what goes into the worker image
# Anything else (docs/, scripts/, README, *.md, tests, Terraform, workflows)
# never changes a tag, so it never forces a rebuild or a deploy.
# Tags are always the first 7 hex characters of that commit, so every clone
# computes the same string (git's %h grows when a prefix is ambiguous).
# scripts/test_image_tags.sh checks these rules.
#
# Usage: scripts/image_tags.sh             api=<tag> / worker=<tag> lines ($GITHUB_OUTPUT, eval)
#        scripts/image_tags.sh --json      {"api": ..., "worker": ...} (Terraform's external data source)
# Terraform needs no -var for the tags; pass -var api_image_tag=... only to
# deliberately deploy something other than the checked-out commit.
set -euo pipefail

cd "$(dirname "$0")/.."

# In a shallow clone, `git log -- <path>` can't see older commits and would
# return HEAD: a tag that was never built. CI must check out with fetch-depth: 0.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "image_tags.sh: shallow clone; fetch full history (actions/checkout fetch-depth: 0)" >&2
  exit 1
fi

# Build inputs of each image (its Dockerfile's COPY lines and .dockerignore),
# minus what only the test stage or the repo uses. Excludes, not an allow-list
# of files: a new file under an image's folder counts by default (worst case
# an extra rebuild, never a stale image).
NOT_IN_IMAGES=(":(exclude,glob)**/*.md")
API_PATHS=(
  app frontend
  ":(exclude)app/tests"
  ":(exclude)app/requirements-dev.txt"
  ":(exclude)frontend/e2e"
  ":(exclude)frontend/playwright.config.ts"
  ":(exclude,glob)frontend/src/**/*.test.ts" # unit tests gate the build (npm test) but aren't bundled
  "${NOT_IN_IMAGES[@]}"
)
WORKER_PATHS=(
  worker
  ":(exclude)worker/tests"
  ":(exclude)worker/requirements-dev.txt"
  "${NOT_IN_IMAGES[@]}"
)

tag_for() { git log -1 --format=%H -- "$@" | cut -c1-7; }
API=$(tag_for "${API_PATHS[@]}")
WORKER=$(tag_for "${WORKER_PATHS[@]}")
[ -n "$API" ] && [ -n "$WORKER" ] || { echo "image_tags.sh: no commits found for the api or worker image" >&2; exit 1; }

case "${1:-}" in
  "") printf 'api=%s\nworker=%s\n' "$API" "$WORKER" ;;
  --json) printf '{"api": "%s", "worker": "%s"}\n' "$API" "$WORKER" ;;
  *) echo "usage: $0 [--json]" >&2; exit 2 ;;
esac
