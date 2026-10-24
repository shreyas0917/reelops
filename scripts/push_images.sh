#!/usr/bin/env bash
# Build the api and worker images, tag each with the git short SHA of the last
# commit that changed what goes into it (scripts/image_tags.sh), and push them
# to ECR (login via the instance role). Terraform computes the same tags
# itself (data.external.image_tags), so nothing needs writing for it.
#
# Needs: ECR repos from terraform/main, docker, aws CLI, a clean app/, frontend/ and worker/.
# Usage: scripts/push_images.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${AWS_REGION:-ap-south-1}"

# Build context and Dockerfile per image. Tags come from scripts/image_tags.sh,
# the one place that decides them (also used by CI).
declare -A CONTEXT=([api]="." [worker]="worker")
declare -A DOCKERFILE=([api]="app/Dockerfile" [worker]="worker/Dockerfile")

# A SHA tag must describe the code inside the image.
if [ -n "$(git status --porcelain -- app frontend worker)" ]; then
  echo "app/, frontend/ or worker/ has uncommitted changes; commit them so the image tag matches the code" >&2
  git status --short -- app frontend worker >&2
  exit 1
fi

URLS=$(terraform -chdir=terraform/main output -json ecr_repository_urls)
url_for() { python3 -I -c "import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])" "$URLS" "$1"; }
REGISTRY=$(url_for api | cut -d/ -f1)

# 12-hour token from the instance role; --password-stdin keeps it out of ps/history.
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
echo "logged in to $REGISTRY"

declare -A TAGS
while IFS='=' read -r name tag; do TAGS[$name]=$tag; done < <(scripts/image_tags.sh)
pushed=()
for name in api worker; do
  tag=${TAGS[$name]}
  repo=$(url_for "$name")

  if aws ecr describe-images --region "$REGION" --repository-name "reelops-$name" \
    --image-ids imageTag="$tag" >/dev/null 2>&1; then
    echo "reelops-$name:$tag already in ECR; skipping (tags are immutable)"
    continue
  fi
  echo "building reelops-$name:$tag"
  # Single image manifest, not an OCI index with attestation children:
  # ECR basic scanning skips indexes, and lifecycle "keep 10" would count
  # (and could expire) the untagged children.
  docker build --quiet --platform linux/amd64 --provenance=false --sbom=false \
    -f "${DOCKERFILE[$name]}" -t "$repo:$tag" "${CONTEXT[$name]}" >/dev/null
  echo "pushing $repo:$tag"
  docker push --quiet "$repo:$tag" >/dev/null
  pushed+=("$name")
done

echo "images ready: api=${TAGS[api]} worker=${TAGS[worker]}"

# Informational: CVE counts from ECR's basic scan of each newly pushed image.
# Poll by hand: right after a push the scan doesn't exist yet, and
# `aws ecr wait image-scan-complete` fails on ScanNotFound instead of waiting.
for name in "${pushed[@]}"; do
  result="not finished after 3 minutes (check the ECR console)"
  for _ in $(seq 36); do
    status=$(aws ecr describe-image-scan-findings --region "$REGION" --repository-name "reelops-$name" \
      --image-id imageTag="${TAGS[$name]}" --query 'imageScanStatus.status' --output text 2>/dev/null || true)
    if [ "$status" = COMPLETE ]; then
      result=$(aws ecr describe-image-scan-findings --region "$REGION" --repository-name "reelops-$name" \
        --image-id imageTag="${TAGS[$name]}" --query 'imageScanFindings.findingSeverityCounts' --output json | tr -d ' \n')
      break
    elif [ "$status" = FAILED ]; then
      result="scan failed"
      break
    fi
    sleep 5
  done
  echo "scan reelops-$name:${TAGS[$name]}: $result"
done
