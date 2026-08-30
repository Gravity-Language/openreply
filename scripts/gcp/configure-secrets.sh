#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${OPENREPLY_GCP_PROJECT_ID:-learngravity-openreply}"
REGION="${OPENREPLY_GCP_REGION:-us-west1}"
SERVICE_ACCOUNT_NAME="${OPENREPLY_GCP_SERVICE_ACCOUNT:-openreply-vm}"
SECRET_NAME="${OPENREPLY_GCP_SECRET_NAME:-openreply-production-env}"
BACKUP_BUCKET="${OPENREPLY_BACKUP_BUCKET:-${PROJECT_ID}-openreply-backups}"
APP_DOMAIN="${OPENREPLY_APP_DOMAIN:-reply.learngravity.com}"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
GIT_SHA="$(git rev-parse --short=12 HEAD)"
DEFAULT_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/openreply/openreply:sha-${GIT_SHA}"

umask 077
CURRENT_ENV_FILE="$(mktemp /tmp/openreply-current-env.XXXXXX)"
ENV_FILE="$(mktemp /tmp/openreply-production-env.XXXXXX)"
cleanup() {
  rm -f "$CURRENT_ENV_FILE" "$ENV_FILE"
}
trap cleanup EXIT

if gcloud secrets describe "$SECRET_NAME" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud secrets versions access latest \
    --secret="$SECRET_NAME" \
    --project="$PROJECT_ID" > "$CURRENT_ENV_FILE"
else
  : > "$CURRENT_ENV_FILE"
fi

current_value() {
  local name="$1"
  sed -n "s/^${name}=//p" "$CURRENT_ENV_FILE" | head -n 1
}

prompt_value() {
  local variable_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local secret="${4:-false}"
  local prefer_default="${5:-false}"
  local supplied_value="${!variable_name:-}"
  local stored_value
  local entered_value

  if [[ -n "$supplied_value" ]]; then
    return
  fi

  stored_value="$(current_value "$variable_name")"

  if [[ "$secret" == "true" ]]; then
    if [[ -n "$stored_value" ]]; then
      read -r -s -p "${prompt} (Enter to keep current): " entered_value
    else
      read -r -s -p "$prompt" entered_value
    fi
    echo
  else
    read -r -p "$prompt" entered_value
  fi

  if [[ "$prefer_default" == "true" ]]; then
    printf -v "$variable_name" '%s' "${entered_value:-$default_value}"
  else
    printf -v "$variable_name" '%s' \
      "${entered_value:-${stored_value:-$default_value}}"
  fi
}

preserve_or_generate() {
  local variable_name="$1"
  local kind="$2"
  local stored_value
  stored_value="$(current_value "$variable_name")"

  if [[ -n "$stored_value" ]]; then
    printf -v "$variable_name" '%s' "$stored_value"
  elif [[ "$kind" == "base64" ]]; then
    printf -v "$variable_name" '%s' "$(openssl rand -base64 32 | tr -d '\n')"
  else
    printf -v "$variable_name" '%s' "$(openssl rand -hex "$kind")"
  fi
}

require_single_line() {
  local name="$1"
  local value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "$name must be a single line." >&2
    exit 1
  fi
}

prompt_value ALLOWED_EMAILS "Allowed login email: " "hello@learngravity.com"
prompt_value EMAIL_FROM "Verified sender [OpenReply <login@learngravity.com>]: " \
  "OpenReply <login@learngravity.com>"
prompt_value RESEND_API_KEY "Resend API key (Enter to configure later)" "pending" true
prompt_value INSTAGRAM_APP_ID "Instagram App ID (Enter to configure later): " "pending"
prompt_value INSTAGRAM_APP_SECRET "Instagram App Secret (Enter to configure later)" "pending" true
prompt_value FACEBOOK_APP_SECRET "Facebook App Secret (Enter to configure later)" "pending" true
prompt_value OPENREPLY_IMAGE "Container image [${DEFAULT_IMAGE}]: " \
  "$DEFAULT_IMAGE" false true

for value_name in \
  ALLOWED_EMAILS EMAIL_FROM RESEND_API_KEY INSTAGRAM_APP_ID \
  INSTAGRAM_APP_SECRET FACEBOOK_APP_SECRET OPENREPLY_IMAGE; do
  require_single_line "$value_name" "${!value_name}"
done

preserve_or_generate NEXTAUTH_SECRET base64
preserve_or_generate CRON_SECRET 32
preserve_or_generate ENCRYPTION_KEY 32
preserve_or_generate WEBHOOK_VERIFY_TOKEN 32
preserve_or_generate POSTGRES_PASSWORD 24
preserve_or_generate REDIS_PASSWORD 24

printf '%s\n' \
  "APP_DOMAIN=${APP_DOMAIN}" \
  "OPENREPLY_IMAGE=${OPENREPLY_IMAGE}" \
  "OPENREPLY_BACKUP_BUCKET=${BACKUP_BUCKET}" \
  "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  "REDIS_PASSWORD=${REDIS_PASSWORD}" \
  "NEXTAUTH_URL=https://${APP_DOMAIN}" \
  "NEXTAUTH_SECRET=${NEXTAUTH_SECRET}" \
  "CRON_SECRET=${CRON_SECRET}" \
  "ENCRYPTION_KEY=${ENCRYPTION_KEY}" \
  "ALLOWED_EMAILS=${ALLOWED_EMAILS}" \
  "RESEND_API_KEY=${RESEND_API_KEY}" \
  "EMAIL_FROM=${EMAIL_FROM}" \
  "META_GRAPH_API_VERSION=v25.0" \
  "INSTAGRAM_APP_ID=${INSTAGRAM_APP_ID}" \
  "INSTAGRAM_APP_SECRET=${INSTAGRAM_APP_SECRET}" \
  "FACEBOOK_APP_SECRET=${FACEBOOK_APP_SECRET}" \
  "WEBHOOK_VERIFY_TOKEN=${WEBHOOK_VERIFY_TOKEN}" \
  "COMMENT_POLL_INTERVAL_MS=300000" \
  "COMMENT_POLL_MAX_PER_SWEEP=30" \
  "COMMENT_POLL_LOOKBACK_HOURS=72" > "$ENV_FILE"

if ! gcloud secrets describe "$SECRET_NAME" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud secrets create "$SECRET_NAME" \
    --replication-policy=automatic \
    --project="$PROJECT_ID"
fi

gcloud secrets versions add "$SECRET_NAME" \
  --data-file="$ENV_FILE" \
  --project="$PROJECT_ID" >/dev/null

gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
  --role=roles/secretmanager.secretAccessor \
  --project="$PROJECT_ID" \
  --quiet >/dev/null

echo "Stored a new ${SECRET_NAME} version in Secret Manager."
echo "No secret values were printed or retained locally."
if [[ "$RESEND_API_KEY" == "pending" ]]; then
  echo "Resend is pending; login email will not work until the secret is updated."
fi
if [[ "$INSTAGRAM_APP_ID" == "pending" ]]; then
  echo "Meta is pending; Instagram connection will be configured after platform health passes."
fi
