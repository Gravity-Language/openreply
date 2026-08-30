#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${OPENREPLY_GCP_PROJECT_ID:-learngravity-openreply}"
REGION="${OPENREPLY_GCP_REGION:-us-west1}"
REPOSITORY="${OPENREPLY_GCP_REPOSITORY:-openreply}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to build an uncommitted tree. Commit the reviewed deployment changes first." >&2
  exit 1
fi

GIT_SHA="$(git rev-parse --short=12 HEAD)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/openreply:sha-${GIT_SHA}"

gcloud builds submit . \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --tag="$IMAGE"

echo "$IMAGE"
