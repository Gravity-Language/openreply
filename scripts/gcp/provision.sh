#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${OPENREPLY_GCP_PROJECT_ID:-learngravity-openreply}"
PROJECT_NAME="${OPENREPLY_GCP_PROJECT_NAME:-LearnGravity OpenReply}"
REGION="${OPENREPLY_GCP_REGION:-us-west1}"
ZONE="${OPENREPLY_GCP_ZONE:-us-west1-b}"
VM_NAME="${OPENREPLY_GCP_VM_NAME:-openreply-prod}"
SERVICE_ACCOUNT_NAME="${OPENREPLY_GCP_SERVICE_ACCOUNT:-openreply-vm}"
REPOSITORY="${OPENREPLY_GCP_REPOSITORY:-openreply}"
SECRET_NAME="${OPENREPLY_GCP_SECRET_NAME:-openreply-production-env}"
BACKUP_BUCKET="${OPENREPLY_BACKUP_BUCKET:-${PROJECT_ID}-openreply-backups}"
BILLING_ACCOUNT="${OPENREPLY_GCP_BILLING_ACCOUNT:-}"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_command gcloud

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1)"
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  echo "No active gcloud account. Run: gcloud auth login" >&2
  exit 1
fi

if [[ -z "$BILLING_ACCOUNT" ]]; then
  BILLING_ACCOUNTS=()
  while IFS= read -r account; do
    [[ -n "$account" ]] && BILLING_ACCOUNTS+=("$account")
  done < <(gcloud billing accounts list --filter=open=true --format='value(name)')
  if [[ "${#BILLING_ACCOUNTS[@]}" -ne 1 ]]; then
    echo "Set OPENREPLY_GCP_BILLING_ACCOUNT to the billing account ID." >&2
    exit 1
  fi
  BILLING_ACCOUNT="${BILLING_ACCOUNTS[0]}"
fi

echo "Using gcloud account: ${ACTIVE_ACCOUNT}"
echo "Provisioning project: ${PROJECT_ID} (${REGION}/${ZONE})"

if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME"
fi

gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
gcloud config set project "$PROJECT_ID" >/dev/null

gcloud services enable \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  iap.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  --project="$PROJECT_ID"

# New projects can use either the legacy Cloud Build service account or the
# Compute Engine default service account for builds. Grant the account GCP
# selects explicitly so `gcloud builds submit --tag` can build and push.
BUILD_SERVICE_ACCOUNT_RESOURCE="$(gcloud builds get-default-service-account \
  --project="$PROJECT_ID" --region="$REGION")"
BUILD_SERVICE_ACCOUNT="${BUILD_SERVICE_ACCOUNT_RESOURCE##*/}"
for role in \
  roles/artifactregistry.writer \
  roles/cloudbuild.builds.builder; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${BUILD_SERVICE_ACCOUNT}" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
done

if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
    --display-name="OpenReply production VM" \
    --project="$PROJECT_ID"
fi

for role in \
  roles/artifactregistry.reader \
  roles/logging.logWriter \
  roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
done

if ! gcloud artifacts repositories describe "$REPOSITORY" \
  --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPOSITORY" \
    --repository-format=docker \
    --location="$REGION" \
    --description="OpenReply production images" \
    --project="$PROJECT_ID"
fi

if ! gcloud storage buckets describe "gs://${BACKUP_BUCKET}" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${BACKUP_BUCKET}" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access
fi

gcloud storage buckets update "gs://${BACKUP_BUCKET}" \
  --lifecycle-file="$(cd "$(dirname "$0")" && pwd)/backup-lifecycle.json" \
  --project="$PROJECT_ID" >/dev/null

gcloud storage buckets add-iam-policy-binding "gs://${BACKUP_BUCKET}" \
  --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
  --role=roles/storage.objectUser \
  --project="$PROJECT_ID" >/dev/null

if ! gcloud compute addresses describe openreply-ip \
  --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute addresses create openreply-ip \
    --region="$REGION" --project="$PROJECT_ID"
fi

STATIC_IP="$(gcloud compute addresses describe openreply-ip \
  --region="$REGION" --project="$PROJECT_ID" --format='value(address)')"

if ! gcloud compute firewall-rules describe openreply-web \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute firewall-rules create openreply-web \
    --project="$PROJECT_ID" \
    --network=default \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:80,tcp:443,udp:443 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=openreply-web
fi

if ! gcloud compute firewall-rules describe openreply-iap-ssh \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute firewall-rules create openreply-iap-ssh \
    --project="$PROJECT_ID" \
    --network=default \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=openreply-iap
fi

gcloud compute project-info add-metadata \
  --project="$PROJECT_ID" \
  --metadata=enable-oslogin=TRUE >/dev/null

if ! gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type=e2-medium \
    --boot-disk-size=30GB \
    --boot-disk-type=pd-balanced \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --address="$STATIC_IP" \
    --service-account="$SERVICE_ACCOUNT_EMAIL" \
    --scopes=cloud-platform \
    --tags=openreply-web,openreply-iap \
    --metadata=enable-oslogin=TRUE
fi

echo
echo "GCP foundation is ready."
echo "Project:       ${PROJECT_ID}"
echo "VM:            ${VM_NAME} (${ZONE})"
echo "Static IP:     ${STATIC_IP}"
echo "Artifact repo: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"
echo "Backup bucket: gs://${BACKUP_BUCKET}"
echo "Secret name:   ${SECRET_NAME} (created by configure-secrets.sh)"
echo
echo "Create this Cloudflare DNS record before TLS verification:"
echo "  Type: A  Name: reply  Value: ${STATIC_IP}  Proxy: DNS only"
