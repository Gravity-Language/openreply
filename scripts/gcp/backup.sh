#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${OPENREPLY_PROJECT_DIR:-/opt/openreply}"
ENV_FILE="${OPENREPLY_ENV_FILE:-/etc/openreply/openreply.env}"
COMPOSE_FILE="${PROJECT_DIR}/compose.gcp.yml"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

BACKUP_BUCKET="$(sed -n 's/^OPENREPLY_BACKUP_BUCKET=//p' "$ENV_FILE" | head -n 1)"
if [[ -z "$BACKUP_BUCKET" ]]; then
  echo "OPENREPLY_BACKUP_BUCKET is missing from ${ENV_FILE}." >&2
  exit 1
fi

umask 077
BACKUP_FILE="$(mktemp /var/tmp/openreply-postgres.XXXXXX.dump)"
cleanup() {
  rm -f "$BACKUP_FILE"
}
trap cleanup EXIT

docker compose \
  --project-directory "$PROJECT_DIR" \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_FILE" \
  exec -T postgres pg_dump \
    --format=custom --compress=9 --no-owner \
    --username=openreply --dbname=openreply > "$BACKUP_FILE"

STAMP="$(date -u '+%Y/%m/%d/openreply-%Y%m%dT%H%M%SZ.dump')"
gcloud storage cp "$BACKUP_FILE" "gs://${BACKUP_BUCKET}/${STAMP}" >/dev/null
echo "Uploaded PostgreSQL backup: gs://${BACKUP_BUCKET}/${STAMP}"
