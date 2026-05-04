#!/usr/bin/env bash
# ================================================================================
# api_setup.sh
# Enables required GCP APIs, configures Identity Platform email/password sign-in,
# creates the Firestore database, and builds composite indexes.
# Called by check_env.sh — safe to run multiple times (idempotent).
# ================================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS="${SCRIPT_DIR}/credentials.json"

PROJECT_ID=$(jq -r '.project_id' "${CREDENTIALS}")
SA_EMAIL=$(jq  -r '.client_email' "${CREDENTIALS}")

gcloud auth activate-service-account --key-file="${CREDENTIALS}" --quiet
gcloud config set project "${PROJECT_ID}" --quiet

# ================================================================================
# Enable GCP APIs
# ================================================================================

echo "NOTE: Enabling required GCP APIs (this may take a minute)..."

gcloud services enable \
  cloudresourcemanager.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com \
  firestore.googleapis.com \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  eventarc.googleapis.com \
  artifactregistry.googleapis.com \
  identitytoolkit.googleapis.com \
  apigateway.googleapis.com \
  servicemanagement.googleapis.com \
  servicecontrol.googleapis.com \
  apikeys.googleapis.com \
  aiplatform.googleapis.com \
  pubsub.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  --project="${PROJECT_ID}" --quiet

echo "NOTE: APIs enabled."

# ================================================================================
# Identity Platform — Enable Email/Password Sign-In
# ================================================================================

echo "NOTE: Enabling Identity Platform email/password sign-in..."

ACCESS_TOKEN=$(gcloud auth print-access-token --quiet)

curl -s -X PATCH \
  "https://identitytoolkit.googleapis.com/admin/v2/projects/${PROJECT_ID}/config?updateMask=signIn" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "signIn": {
      "email": { "enabled": true, "passwordRequired": true }
    }
  }' > /dev/null

echo "NOTE: Identity Platform email/password sign-in enabled."

# ================================================================================
# Firestore Database
# ================================================================================

echo "NOTE: Creating Firestore database (native mode, us-central1)..."

gcloud firestore databases create \
  --location=us-central1 \
  --project="${PROJECT_ID}" 2>/dev/null || \
  echo "NOTE: Firestore database already exists, skipping."

# ================================================================================
# Firestore Composite Indexes
# ================================================================================

echo "NOTE: Creating Firestore composite indexes..."

# Index on resume_app_jobs for list-by-owner queries (newest first)
gcloud firestore indexes composite create \
  --collection-group="resume_app_jobs" \
  --field-config "field-path=owner,order=ascending" \
  --field-config "field-path=created_at,order=descending" \
  --async \
  --project="${PROJECT_ID}" 2>/dev/null || true

# Index on resume_app_resumes for list-by-owner queries (newest first)
gcloud firestore indexes composite create \
  --collection-group="resume_app_resumes" \
  --field-config "field-path=owner,order=ascending" \
  --field-config "field-path=created_at,order=descending" \
  --async \
  --project="${PROJECT_ID}" 2>/dev/null || true

echo "NOTE: Firestore indexes created (may take a few minutes to build)."
