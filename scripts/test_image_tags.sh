#!/usr/bin/env bash
# Tests for scripts/image_tags.sh: only what goes into an image changes its
# tag. Builds a throwaway git repo (no dependence on this repo's history, so it
# also runs in CI's shallow checkout), commits to one kind of path at a time,
# and checks which tag moved.
# Usage: scripts/test_image_tags.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/image_tags.sh"
REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT
cd "$REPO"
git init -q -b main
git config user.name "image-tags test"
git config user.email "test@example.com"
mkdir -p scripts && cp "$SCRIPT" scripts/image_tags.sh

touch_and_commit() { # touch_and_commit <path>...: change the files and commit
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "$RANDOM $f" >>"$f"; done
  git add -A && git commit -q -m "change $*"
}
tags() { scripts/image_tags.sh | tr '\n' ' '; }
head7() { git rev-parse HEAD | cut -c1-7; }

failures=0
check() { # check <description> <expected tags> <actual tags>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; failures=$((failures + 1)); fi
}

# A repo shaped like ReelOps, with one commit per image.
touch_and_commit app/Dockerfile app/Dockerfile.dockerignore app/requirements.txt app/reelops_api/main.py \
  frontend/package.json frontend/src/App.tsx
api=$(head7)
touch_and_commit worker/Dockerfile worker/.dockerignore worker/requirements.txt worker/reelops_worker/consumer.py
worker=$(head7)
check "baseline" "api=$api worker=$worker " "$(tags)"

# Each check compares with the tags just before that commit, so one wrong
# rule fails one line instead of every line after it.

# Never part of an image: no tag may move.
for path in \
  docs/failure-tests.md docs/ui.png README.md CLAUDE.md scripts/push_images.sh scripts/chaos/lib.sh \
  terraform/main/ecs.tf .github/workflows/ci.yml \
  app/tests/test_api.py app/requirements-dev.txt app/README.md \
  frontend/e2e/states.spec.ts frontend/playwright.config.ts frontend/src/lib/status.test.ts frontend/README.md \
  worker/tests/test_consumer.py worker/requirements-dev.txt worker/reelops_worker/NOTES.md; do
  before=$(tags)
  touch_and_commit "$path"
  check "$path doesn't change a tag" "$before" "$(tags)"
done

# Image inputs: exactly that image's tag moves, to this commit.
for path in app/reelops_api/main.py app/requirements.txt app/Dockerfile app/Dockerfile.dockerignore \
  frontend/src/App.tsx frontend/src/lib/status.ts frontend/package.json frontend/index.html; do
  worker=$(tags | sed 's/.*worker=//; s/ $//')
  touch_and_commit "$path"
  api=$(head7)
  check "$path changes the api tag only" "api=$api worker=$worker " "$(tags)"
done
for path in worker/reelops_worker/consumer.py worker/requirements.txt worker/Dockerfile worker/.dockerignore; do
  api=$(tags | sed 's/^api=//; s/ .*//')
  touch_and_commit "$path"
  worker=$(head7)
  check "$path changes the worker tag only" "api=$api worker=$worker " "$(tags)"
done

# --json is what Terraform's external data source reads.
check "--json output" "{\"api\": \"$api\", \"worker\": \"$worker\"}" "$(scripts/image_tags.sh --json)"

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all image tag rules hold"
