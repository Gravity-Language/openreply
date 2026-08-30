#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${OPENREPLY_GCP_PROJECT_ID:-learngravity-openreply}"
REGION="${OPENREPLY_GCP_REGION:-us-west1}"
ZONE="${OPENREPLY_GCP_ZONE:-us-west1-b}"
VM_NAME="${OPENREPLY_GCP_VM_NAME:-openreply-prod}"
GIT_SHA="$(git rev-parse --short=12 HEAD)"
RELEASE_ID="openreply-deploy-${GIT_SHA}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy an uncommitted tree." >&2
  exit 1
fi

umask 077
STAGE_DIR="$(mktemp -d /tmp/openreply-release.XXXXXX)"
ARCHIVE="${STAGE_DIR}/${RELEASE_ID}.tar.gz"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

mkdir -p "${STAGE_DIR}/payload/scripts/gcp"
cp Caddyfile compose.gcp.yml "${STAGE_DIR}/payload/"
cp scripts/cron.sh "${STAGE_DIR}/payload/scripts/"
cp \
  scripts/gcp/backup.sh \
  scripts/gcp/bootstrap.sh \
  scripts/gcp/deploy.sh \
  scripts/gcp/install-deployment.sh \
  scripts/gcp/openreply-backup.service \
  scripts/gcp/openreply-backup.timer \
  scripts/gcp/restore.sh \
  "${STAGE_DIR}/payload/scripts/gcp/"

tar -czf "$ARCHIVE" -C "${STAGE_DIR}/payload" .

gcloud compute scp "$ARCHIVE" "${VM_NAME}:/tmp/${RELEASE_ID}.tar.gz" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --tunnel-through-iap

REMOTE_COMMAND="set -euo pipefail; \
  install -d -m 0700 /tmp/${RELEASE_ID}; \
  tar -xzf /tmp/${RELEASE_ID}.tar.gz -C /tmp/${RELEASE_ID}; \
  sudo bash /tmp/${RELEASE_ID}/scripts/gcp/bootstrap.sh; \
  sudo bash /tmp/${RELEASE_ID}/scripts/gcp/install-deployment.sh /tmp/${RELEASE_ID}; \
  sudo env OPENREPLY_GCP_PROJECT_ID=${PROJECT_ID} OPENREPLY_GCP_REGION=${REGION} \
    bash /opt/openreply/scripts/gcp/deploy.sh"

gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --command="$REMOTE_COMMAND"

echo "Released ${GIT_SHA} to ${VM_NAME}."
