#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${OPENREPLY_GCP_PROJECT_ID:-learngravity-openreply}"
REGION="${OPENREPLY_GCP_REGION:-us-west1}"
SECRET_NAME="${OPENREPLY_GCP_SECRET_NAME:-openreply-production-env}"
PROJECT_DIR="${OPENREPLY_PROJECT_DIR:-/opt/openreply}"
ENV_FILE="${OPENREPLY_ENV_FILE:-/etc/openreply/openreply.env}"
COMPOSE_FILE="${PROJECT_DIR}/compose.gcp.yml"
REGISTRY_HOST="${REGION}-docker.pkg.dev"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

umask 077
gcloud secrets versions access latest \
  --secret="$SECRET_NAME" \
  --project="$PROJECT_ID" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

gcloud auth configure-docker "$REGISTRY_HOST" --quiet >/dev/null

compose() {
  docker compose \
    --project-directory "$PROJECT_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" "$@"
}

compose pull
compose up -d --wait postgres redis
compose --profile tools run --rm migrate
compose up -d --remove-orphans web worker caddy

health_ok=false
for _ in $(seq 1 30); do
  if compose exec -T web wget -q -O- http://127.0.0.1:3000/api/health \
    | grep -q '"status":"ok"'; then
    health_ok=true
    break
  fi
  sleep 5
done

if [[ "$health_ok" != "true" ]]; then
  echo "OpenReply did not become healthy within 150 seconds." >&2
  compose ps
  compose logs --tail=100 web worker
  exit 1
fi

compose up -d cron
compose ps
echo "Deployment healthy. Public TLS will be available after DNS points at the VM."
