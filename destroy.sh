#!/usr/bin/env bash
# ================================================================================
# destroy.sh
# Tears down all Azure infrastructure in reverse-stage order.
# ================================================================================
source "$(dirname "$0")/aoai-config.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

./check_env.sh

# ── Read 01-backend outputs before state is destroyed ─────────────────────────

cd "${SCRIPT_DIR}/01-backend"
WEB_STORAGE_NAME=$(terraform output -raw web_storage_name           2>/dev/null || true)
WEB_BASE_URL=$(terraform output -raw web_base_url                   2>/dev/null || true)
MEDIA_STORAGE_ID=$(terraform output -raw media_storage_id           2>/dev/null || true)
MEDIA_BLOB_ENDPOINT=$(terraform output -raw media_blob_endpoint     2>/dev/null || true)
COSMOS_ENDPOINT=$(terraform output -raw cosmos_endpoint             2>/dev/null || true)
COSMOS_ACCOUNT_NAME=$(terraform output -raw cosmos_account_name     2>/dev/null || true)
COSMOS_ROLE_DEF_ID=$(terraform output -raw cosmos_role_definition_id 2>/dev/null || true)
SB_NAMESPACE_FQDN=$(terraform output -raw servicebus_namespace_fqdn 2>/dev/null || true)
SB_QUEUE_NAME=$(terraform output -raw servicebus_queue_name         2>/dev/null || true)
SB_QUEUE_ID=$(terraform output -raw servicebus_queue_id             2>/dev/null || true)
AOAI_ENDPOINT=$(terraform output -raw aoai_endpoint                 2>/dev/null || true)
AOAI_ACCOUNT_ID=$(terraform output -raw aoai_account_id             2>/dev/null || true)
ENTRA_CLIENT_ID=$(terraform output -raw entra_client_id             2>/dev/null || true)
ENTRA_AUTHORITY=$(terraform output -raw entra_authority             2>/dev/null || true)
cd "${SCRIPT_DIR}"


# ── Destroy web app first (depends on web storage from 01-backend) ────────────

echo "NOTE: Destroying web app..."
cd "${SCRIPT_DIR}/03-webapp"
terraform init -upgrade
terraform destroy -auto-approve \
  -var="web_storage_name=${WEB_STORAGE_NAME:-placeholder}"
cd "${SCRIPT_DIR}"


# ── Destroy Function App ───────────────────────────────────────────────────────

echo "NOTE: Destroying Function App..."
cd "${SCRIPT_DIR}/02-functions"
terraform init -upgrade
terraform destroy -auto-approve \
  -var="resource_group_name=resume-app-rg" \
  -var="servicebus_namespace_fqdn=${SB_NAMESPACE_FQDN:-placeholder}" \
  -var="servicebus_queue_name=${SB_QUEUE_NAME:-placeholder}" \
  -var="servicebus_queue_id=${SB_QUEUE_ID:-placeholder}" \
  -var="cosmos_endpoint=${COSMOS_ENDPOINT:-placeholder}" \
  -var="cosmos_account_name=${COSMOS_ACCOUNT_NAME:-placeholder}" \
  -var="cosmos_role_definition_id=${COSMOS_ROLE_DEF_ID:-placeholder}" \
  -var="media_storage_id=${MEDIA_STORAGE_ID:-placeholder}" \
  -var="media_blob_endpoint=${MEDIA_BLOB_ENDPOINT:-placeholder}" \
  -var="aoai_endpoint=${AOAI_ENDPOINT:-placeholder}" \
  -var="aoai_account_id=${AOAI_ACCOUNT_ID:-placeholder}" \
  -var="aoai_model_deployment=${AOAI_MODEL_DEPLOYMENT}" \
  -var="entra_tenant_name=${ENTRA_TENANT_NAME}" \
  -var="entra_tenant_id=${ENTRA_TENANT_ID}" \
  -var="entra_client_id=${ENTRA_CLIENT_ID:-placeholder}" \
  -var="web_origin=${WEB_BASE_URL:-placeholder}"
cd "${SCRIPT_DIR}"


# ── Remove app from Entra user flow ───────────────────────────────────────────

echo "NOTE: Removing resume-app from user flow '${ENTRA_USER_FLOW_NAME}'..."

# Retried up to 10 times — failures are non-fatal; destroy continues regardless
_remove_app() {
  if [[ -z "$ENTRA_CLIENT_ID" ]]; then
    echo "NOTE: No Entra client ID in state. Skipping association cleanup."
    return 0
  fi

  GRAPH_TOKEN=$(curl -s -X POST \
    "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${ENTRA_SP_CLIENT_ID}" \
    --data-urlencode "client_secret=${ENTRA_SP_CLIENT_SECRET}" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
    | jq -r '.access_token')

  if [[ -z "$GRAPH_TOKEN" || "$GRAPH_TOKEN" == "null" ]]; then
    echo "WARNING: Could not acquire Graph token."
    return 1
  fi

  FLOW_ID=$(curl -s -G \
    --data-urlencode "\$filter=displayName eq '${ENTRA_USER_FLOW_NAME}'" \
    "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows" \
    -H "Authorization: Bearer ${GRAPH_TOKEN}" \
    | jq -r '.value[0].id')

  if [[ -z "$FLOW_ID" || "$FLOW_ID" == "null" ]]; then
    echo "NOTE: User flow '${ENTRA_USER_FLOW_NAME}' not found. Skipping."
    return 0
  fi

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows/${FLOW_ID}/conditions/applications/includeApplications/${ENTRA_CLIENT_ID}" \
    -H "Authorization: Bearer ${GRAPH_TOKEN}")

  if [[ "$HTTP_STATUS" == "204" ]]; then
    echo "NOTE: App removed from user flow."
    return 0
  elif [[ "$HTTP_STATUS" == "404" ]]; then
    echo "NOTE: App was not associated with user flow (already clean)."
    return 0
  fi

  echo "WARNING: Unexpected HTTP ${HTTP_STATUS} removing app from user flow."
  return 1
}

_GRAPH_MAX=10
_GRAPH_DELAY=30
for _attempt in $(seq 1 $_GRAPH_MAX); do
  if _remove_app; then
    break
  fi
  if [[ $_attempt -lt $_GRAPH_MAX ]]; then
    echo "NOTE: Retrying in ${_GRAPH_DELAY}s (attempt ${_attempt}/${_GRAPH_MAX})..."
    sleep $_GRAPH_DELAY
  else
    echo "WARNING: User flow cleanup failed after ${_GRAPH_MAX} attempts. Continuing..."
  fi
done


# ── Destroy backend infrastructure ────────────────────────────────────────────

echo "NOTE: Destroying backend infrastructure..."
cd "${SCRIPT_DIR}/01-backend"

export TF_VAR_entra_tenant_id="$ENTRA_TENANT_ID"
export TF_VAR_entra_tenant_name="$ENTRA_TENANT_NAME"
export TF_VAR_entra_sp_client_id="$ENTRA_SP_CLIENT_ID"
export TF_VAR_entra_sp_client_secret="$ENTRA_SP_CLIENT_SECRET"
export TF_VAR_aoai_model_deployment="$AOAI_MODEL_DEPLOYMENT"

terraform init -upgrade
terraform destroy -auto-approve
cd "${SCRIPT_DIR}"

echo "NOTE: Teardown complete."
