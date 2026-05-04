#!/usr/bin/env bash
# ================================================================================
# apply.sh
# Orchestrates end-to-end deployment of the GCP resume scorer:
#   1. Validate environment (tools, credentials, Vertex AI model access)
#   2. Phase 1 — 01-backend: GCS, Pub/Sub, service accounts, Identity Platform
#   3. Phase 2 — 02-functions: Cloud Functions + API Gateway
#   4. Phase 3 — 03-webapp: GCS public bucket + frontend site
# ================================================================================
source "$(dirname "$0")/gemini-config.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS="${SCRIPT_DIR}/credentials.json"

# ================================================================================
# Environment Validation
# ================================================================================

echo "NOTE: Running environment validation..."
"${SCRIPT_DIR}/check_env.sh"

export PROJECT_ID=$(jq -r '.project_id' "${CREDENTIALS}")

# ================================================================================
# Phase 1 — Backend (GCS, Pub/Sub, IAM, Identity Platform key)
# ================================================================================

echo "NOTE: Deploying 01-backend..."
cd "${SCRIPT_DIR}/01-backend"
terraform init -reconfigure -input=false
terraform apply -auto-approve

export MEDIA_BUCKET=$(terraform output -raw media_bucket_name)
export FIREBASE_API_KEY=$(terraform output -json firebase_api_key | jq -r '.')

# ================================================================================
# Phase 2 — Cloud Functions + API Gateway
# ================================================================================

echo "NOTE: Deploying 02-functions..."
cd "${SCRIPT_DIR}/02-functions"

# Install Python dependencies into each function source directory so they are
# packaged into the ZIP and deployed to Cloud Functions.
pip install -r code/api/requirements.txt    -t code/api/    -q --upgrade --no-deps
pip install -r code/worker/requirements.txt -t code/worker/ -q --upgrade --no-deps

terraform init -reconfigure -input=false
terraform apply -auto-approve \
  -var="media_bucket_name=${MEDIA_BUCKET}" \
  -var="gemini_model_id=${GEMINI_MODEL_ID}"

export GATEWAY_URL=$(terraform output -raw gateway_url)

# ================================================================================
# Phase 3 — Webapp bucket
# ================================================================================

echo "NOTE: Deploying 03-webapp..."
cd "${SCRIPT_DIR}/03-webapp"
terraform init -reconfigure -input=false
terraform apply -auto-approve

export WEBAPP_BUCKET=$(terraform output -raw webapp_bucket)

# ================================================================================
# Generate Frontend Config
# ================================================================================

echo "NOTE: Generating frontend config.js..."
cd "${SCRIPT_DIR}/03-webapp/site"

export API_BASE_URL="${GATEWAY_URL}"
envsubst < js/config.js.tmpl > js/config.js

# ================================================================================
# Upload Site Files
# ================================================================================

echo "NOTE: Uploading site files to gs://${WEBAPP_BUCKET}..."
gcloud storage cp -r . "gs://${WEBAPP_BUCKET}/" --quiet
gcloud storage rm "gs://${WEBAPP_BUCKET}/js/config.js.tmpl" --quiet 2>/dev/null || true

# ================================================================================
# Post-Deploy Validation
# ================================================================================

echo "NOTE: Running post-deployment validation..."
cd "${SCRIPT_DIR}"
./validate.sh

# ================================================================================
# End
# ================================================================================
