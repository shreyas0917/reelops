#!/usr/bin/env bash
# The single place that decides image tags (used by push_images.sh, local
# Terraform via images.auto.tfvars, and CI):
#   api    = last commit touching app/ or frontend/, except test-only paths
#            (the API image serves the UI)
#   worker = last commit touching worker/
# Tags are always the first 7 hex characters of that commit, so every clone
# computes the same string (git's %h grows when a prefix is ambiguous).
#
# Usage: scripts/image_tags.sh             api=<tag> / worker=<tag> lines ($GITHUB_OUTPUT, eval)
#        scripts/image_tags.sh --tfvars    images.auto.tfvars contents
#        scripts/image_tags.sh --tf-args   -var=... flags for terraform plan/apply
set -euo pipefail

cd "$(dirname "$0")/.."

# In a shallow clone, `git log -- <path>` can't see older commits and would
# return HEAD: a tag that was never built. CI must check out with fetch-depth: 0.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "image_tags.sh: shallow clone; fetch full history (actions/checkout fetch-depth: 0)" >&2
  exit 1
fi

tag_for() { git log -1 --format=%H -- "$@" | cut -c1-7; }
# Paths that never reach the shipped API image (app/Dockerfile.dockerignore and
# the runtime stage): a commit touching only these must not force a new tag,
# a rebuild and a deploy. An exclude list on purpose: a new build input is
# counted by default (worst case an extra rebuild, never a stale image).
# *.test.ts files gate the build (npm test) but are never bundled into dist/.
API_TEST_ONLY=(
  ":(exclude)app/tests"
  ":(exclude)app/requirements-dev.txt"
  ":(exclude)frontend/e2e"
  ":(exclude)frontend/playwright.config.ts"
  ":(exclude,glob)frontend/src/**/*.test.ts"
)
API=$(tag_for app frontend "${API_TEST_ONLY[@]}")
WORKER=$(tag_for worker)
[ -n "$API" ] && [ -n "$WORKER" ] || { echo "image_tags.sh: no commits found for app/frontend or worker" >&2; exit 1; }

case "${1:-}" in
  "") printf 'api=%s\nworker=%s\n' "$API" "$WORKER" ;;
  --tfvars) printf '# Written by scripts/push_images.sh. Git-ignored. Image tags to deploy.\napi_image_tag    = "%s"\nworker_image_tag = "%s"\n' "$API" "$WORKER" ;;
  --tf-args) printf -- '-var=api_image_tag=%s -var=worker_image_tag=%s\n' "$API" "$WORKER" ;;
  *) echo "usage: $0 [--tfvars | --tf-args]" >&2; exit 2 ;;
esac
