#!/usr/bin/env bash
# The single place that decides image tags (used by push_images.sh, local
# Terraform via images.auto.tfvars, and CI):
#   api    = last commit touching app/ or frontend/  (the API image serves the UI)
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
API=$(tag_for app frontend)
WORKER=$(tag_for worker)
[ -n "$API" ] && [ -n "$WORKER" ] || { echo "image_tags.sh: no commits found for app/frontend or worker" >&2; exit 1; }

case "${1:-}" in
  "") printf 'api=%s\nworker=%s\n' "$API" "$WORKER" ;;
  --tfvars) printf '# Written by scripts/push_images.sh. Git-ignored. Image tags to deploy.\napi_image_tag    = "%s"\nworker_image_tag = "%s"\n' "$API" "$WORKER" ;;
  --tf-args) printf -- '-var=api_image_tag=%s -var=worker_image_tag=%s\n' "$API" "$WORKER" ;;
  *) echo "usage: $0 [--tfvars | --tf-args]" >&2; exit 2 ;;
esac
