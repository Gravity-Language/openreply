#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${OPENREPLY_PROJECT_DIR:-/opt/openreply}"
ENV_FILE="${OPENREPLY_ENV_FILE:-/etc/openreply/openreply.env}"
COMPOSE_FILE="${PROJECT_DIR}/compose.gcp.yml"

if [[ "${2:-}" != "--confirm-destructive-restore" || -z "${1:-}" ]]; then
  echo "Usage: $0 gs://BUCKET/path.dump --confirm-destructive-restore" >&2
  echo "This replaces the current OpenReply database." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

SOURCE="$1"
umask 077
RESTORE_FILE="$(mktemp /var/tmp/openreply-restore.XXXXXX.dump)"
cleanup() {
  rm -f "$RESTORE_FILE"
}
trap cleanup EXIT

compose() {
  docker compose \
    --project-directory "$PROJECT_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" "$@"
}

"${PROJECT_DIR}/scripts/gcp/backup.sh"
gcloud storage cp "$SOURCE" "$RESTORE_FILE" >/dev/null

compose stop web worker cron
compose exec -T postgres pg_restore \
  --clean --if-exists --no-owner \
  --username=openreply --dbname=openreply < "$RESTORE_FILE"
compose up -d web worker cron caddy

echo "Restore completed from ${SOURCE}. Verify /api/health and application data."
