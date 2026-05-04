#!/usr/bin/env bash
# ================================================================================
# check_env.sh
# Validates local tooling, GCP credentials, and Vertex AI model access before
# apply.sh or destroy.sh are allowed to proceed.
# ================================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS="${SCRIPT_DIR}/credentials.json"

# ================================================================================
# Tool Validation
# ================================================================================

echo "NOTE: Validating required commands in PATH."

MISSING=0
for CMD in gcloud terraform jq pip; do
  if ! command -v "${CMD}" > /dev/null 2>&1; then
    echo "ERROR: ${CMD} not found in PATH."
    MISSING=1
  else
    echo "NOTE: ${CMD} found."
  fi
done

[ "${MISSING}" -ne 0 ] && { echo "ERROR: Missing required tools."; exit 1; }

# ================================================================================
# Credentials
# ================================================================================

if [ ! -f "${CREDENTIALS}" ]; then
  echo "ERROR: credentials.json not found at ${CREDENTIALS}."
  exit 1
fi

PROJECT_ID=$(jq -r '.project_id' "${CREDENTIALS}" 2>/dev/null || echo "")
SA_EMAIL=$(jq  -r '.client_email' "${CREDENTIALS}" 2>/dev/null || echo "")

if [ -z "${PROJECT_ID}" ] || [ -z "${SA_EMAIL}" ]; then
  echo "ERROR: credentials.json missing project_id or client_email."
  exit 1
fi

echo "NOTE: credentials.json found — project=${PROJECT_ID}, sa=${SA_EMAIL}"

# ================================================================================
# GCP Authentication
# ================================================================================

gcloud auth activate-service-account --key-file="${CREDENTIALS}" --quiet
gcloud config set project "${PROJECT_ID}" --quiet
echo "NOTE: Authenticated as ${SA_EMAIL}."

# ================================================================================
# API Setup
# ================================================================================

echo "NOTE: Running api_setup.sh (enables APIs, Firestore, Identity Platform)..."
"${SCRIPT_DIR}/api_setup.sh"

# ================================================================================
# Vertex AI Model Check
# ================================================================================

GEMINI_MODEL_ID="${GEMINI_MODEL_ID:-gemini-2.5-flash}"
echo "NOTE: Testing Vertex AI model ${GEMINI_MODEL_ID}..."

ACCESS_TOKEN=$(gcloud auth print-access-token --quiet)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "https://aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/global/publishers/google/models/${GEMINI_MODEL_ID}:generateContent" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Say OK"}]}]}')

if [ "${HTTP_CODE}" = "200" ]; then
  echo "NOTE: Vertex AI model ${GEMINI_MODEL_ID} accessible."
else
  echo "ERROR: Vertex AI model ${GEMINI_MODEL_ID} not accessible (HTTP ${HTTP_CODE})."
  echo "       Ensure the model is enabled in Model Garden and the SA has aiplatform.user."
  exit 1
fi
