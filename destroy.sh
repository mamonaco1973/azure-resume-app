#!/usr/bin/env bash
# ================================================================================
# destroy.sh
# Tears down all GCP infrastructure in reverse-phase order.
# ================================================================================
source "$(dirname "$0")/gemini-config.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS="${SCRIPT_DIR}/credentials.json"

PROJECT_ID=$(jq -r '.project_id' "${CREDENTIALS}")
SA_EMAIL=$(jq -r '.client_email' "${CREDENTIALS}")

# ================================================================================
# Authenticate
# ================================================================================

gcloud auth activate-service-account --key-file="${CREDENTIALS}" --quiet
gcloud config set project "${PROJECT_ID}" --quiet

# ================================================================================
# Phase 3 — Webapp bucket
# ================================================================================

echo "NOTE: Destroying 03-webapp..."
cd "${SCRIPT_DIR}/03-webapp"
terraform init -reconfigure -input=false
terraform destroy -auto-approve

# ================================================================================
# Phase 2 — Cloud Functions + API Gateway
# ================================================================================

echo "NOTE: Destroying 02-functions..."
cd "${SCRIPT_DIR}/02-functions"
terraform init -reconfigure -input=false
terraform destroy -auto-approve \
  -var="media_bucket_name=placeholder" \
  -var="gemini_model_id=${GEMINI_MODEL_ID}"

# ================================================================================
# Phase 1 — Backend (GCS, Pub/Sub, IAM, Identity Platform)
# ================================================================================

echo "NOTE: Emptying media bucket before destroy..."
MEDIA_BUCKET=$(cd "${SCRIPT_DIR}/01-backend" && terraform output -raw media_bucket_name 2>/dev/null || echo "")
if [ -n "${MEDIA_BUCKET}" ]; then
  gcloud storage rm -r "gs://${MEDIA_BUCKET}/**" --quiet 2>/dev/null || true
fi

# Delete Firestore documents from both collections
echo "NOTE: Deleting Firestore documents..."
for COLLECTION in resume_app_jobs resume_app_resumes; do
  PAGE_TOKEN=""
  while true; do
    RESPONSE=$(curl -s -X GET \
      "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/${COLLECTION}?pageSize=100&pageToken=${PAGE_TOKEN}" \
      -H "Authorization: Bearer $(gcloud auth print-access-token --quiet)")

    echo "${RESPONSE}" | jq -r '.documents[]?.name // empty' | while read -r DOC_NAME; do
      curl -s -X DELETE \
        "https://firestore.googleapis.com/v1/${DOC_NAME}" \
        -H "Authorization: Bearer $(gcloud auth print-access-token --quiet)" > /dev/null
    done

    PAGE_TOKEN=$(echo "${RESPONSE}" | jq -r '.nextPageToken // empty')
    [ -z "${PAGE_TOKEN}" ] && break
  done
done

echo "NOTE: Destroying 01-backend..."
cd "${SCRIPT_DIR}/01-backend"
terraform init -reconfigure -input=false
terraform destroy -auto-approve

echo "NOTE: Infrastructure teardown complete."
