#!/usr/bin/env bash
# ================================================================================
# apply.sh
# Orchestrates end-to-end deployment of the Azure resume scorer:
#   1. Validate environment (tools, Azure credentials, Entra connectivity)
#   2. Stage 1 — 01-backend: SB, Cosmos DB, Blob Storage, AOAI, Entra app
#   3. Associate Entra app with user flow via Graph API
#   4. Stage 2 — 02-functions: Function App compute + RBAC
#   5. Deploy function code via zip deploy
#   6. Stage 3 — 03-webapp: SPA assets to Blob Storage $web
# ================================================================================
source "$(dirname "$0")/aoai-config.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ================================================================================
# Environment Validation
# ================================================================================

echo "NOTE: Running environment validation..."
"${SCRIPT_DIR}/check_env.sh"


# ── Stage 1: Core infrastructure (SB, Cosmos, Storage, AOAI, Entra app) ────────

echo "NOTE: Deploying backend infrastructure..."
cd "${SCRIPT_DIR}/01-backend"

export TF_VAR_entra_tenant_id="$ENTRA_TENANT_ID"
export TF_VAR_entra_tenant_name="$ENTRA_TENANT_NAME"
export TF_VAR_entra_sp_client_id="$ENTRA_SP_CLIENT_ID"
export TF_VAR_entra_sp_client_secret="$ENTRA_SP_CLIENT_SECRET"
export TF_VAR_aoai_model_deployment="$AOAI_MODEL_DEPLOYMENT"

terraform init -upgrade
terraform apply -auto-approve || true
terraform apply -auto-approve

RESOURCE_GROUP=$(terraform output -raw resource_group_name)
WEB_STORAGE_NAME=$(terraform output -raw web_storage_name)
WEB_BASE_URL=$(terraform output -raw web_base_url)
MEDIA_STORAGE_ID=$(terraform output -raw media_storage_id)
MEDIA_BLOB_ENDPOINT=$(terraform output -raw media_blob_endpoint)
COSMOS_ENDPOINT=$(terraform output -raw cosmos_endpoint)
COSMOS_ACCOUNT_NAME=$(terraform output -raw cosmos_account_name)
COSMOS_ROLE_DEF_ID=$(terraform output -raw cosmos_role_definition_id)
SB_NAMESPACE_FQDN=$(terraform output -raw servicebus_namespace_fqdn)
SB_QUEUE_NAME=$(terraform output -raw servicebus_queue_name)
SB_QUEUE_ID=$(terraform output -raw servicebus_queue_id)
AOAI_ENDPOINT=$(terraform output -raw aoai_endpoint)
AOAI_ACCOUNT_ID=$(terraform output -raw aoai_account_id)
ENTRA_CLIENT_ID=$(terraform output -raw entra_client_id)
ENTRA_AUTHORITY=$(terraform output -raw entra_authority)

cd "${SCRIPT_DIR}"


# ── Stage 1b: Associate app with Entra user flow via Graph API ───────────────

echo "NOTE: Associating resume-app with user flow '${ENTRA_USER_FLOW_NAME}'..."

# ARM SP lacks Graph permissions in the External tenant — acquire a separate
# token using the Entra-scoped SP. Retried up to 10 times for throttling.
_associate_app() {
  GRAPH_TOKEN=$(curl -s -X POST \
    "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${ENTRA_SP_CLIENT_ID}" \
    --data-urlencode "client_secret=${ENTRA_SP_CLIENT_SECRET}" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
    | jq -r '.access_token')

  if [[ -z "$GRAPH_TOKEN" || "$GRAPH_TOKEN" == "null" ]]; then
    echo "WARNING: Failed to acquire Graph API token."
    return 1
  fi

  FLOW_ID=$(curl -s -G \
    --data-urlencode "\$filter=displayName eq '${ENTRA_USER_FLOW_NAME}'" \
    "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows" \
    -H "Authorization: Bearer ${GRAPH_TOKEN}" \
    | jq -r '.value[0].id')

  if [[ -z "$FLOW_ID" || "$FLOW_ID" == "null" ]]; then
    echo "WARNING: User flow '${ENTRA_USER_FLOW_NAME}' not found in tenant."
    return 1
  fi

  # Skip if already linked — makes apply.sh idempotent
  ALREADY_LINKED=$(curl -s \
    "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows/${FLOW_ID}/conditions/applications/includeApplications" \
    -H "Authorization: Bearer ${GRAPH_TOKEN}" \
    | jq -r --arg id "${ENTRA_CLIENT_ID}" '.value[] | select(.appId == $id) | .appId')

  if [[ -n "$ALREADY_LINKED" ]]; then
    echo "NOTE: App already associated with user flow '${ENTRA_USER_FLOW_NAME}'."
    return 0
  fi

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows/${FLOW_ID}/conditions/applications/includeApplications" \
    -H "Authorization: Bearer ${GRAPH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"@odata.type\": \"#microsoft.graph.authenticationConditionApplication\", \"appId\": \"${ENTRA_CLIENT_ID}\"}")

  if [[ "$HTTP_STATUS" == "201" ]]; then
    echo "NOTE: App associated with user flow '${ENTRA_USER_FLOW_NAME}'."
    return 0
  fi

  echo "WARNING: Failed to associate app with user flow (HTTP ${HTTP_STATUS})."
  return 1
}

_GRAPH_MAX=10
_GRAPH_DELAY=30
for _attempt in $(seq 1 $_GRAPH_MAX); do
  if _associate_app; then
    break
  fi
  if [[ $_attempt -lt $_GRAPH_MAX ]]; then
    echo "NOTE: Retrying in ${_GRAPH_DELAY}s (attempt ${_attempt}/${_GRAPH_MAX})..."
    sleep $_GRAPH_DELAY
  else
    echo "ERROR: Failed to associate app with user flow after ${_GRAPH_MAX} attempts."
    exit 1
  fi
done


# ── Stage 2: Function App (compute + RBAC) ────────────────────────────────────

echo "NOTE: Deploying Function App..."
cd "${SCRIPT_DIR}/02-functions"

export TF_VAR_resource_group_name="$RESOURCE_GROUP"
export TF_VAR_servicebus_namespace_fqdn="$SB_NAMESPACE_FQDN"
export TF_VAR_servicebus_queue_name="$SB_QUEUE_NAME"
export TF_VAR_servicebus_queue_id="$SB_QUEUE_ID"
export TF_VAR_cosmos_endpoint="$COSMOS_ENDPOINT"
export TF_VAR_cosmos_account_name="$COSMOS_ACCOUNT_NAME"
export TF_VAR_cosmos_role_definition_id="$COSMOS_ROLE_DEF_ID"
export TF_VAR_media_storage_id="$MEDIA_STORAGE_ID"
export TF_VAR_media_blob_endpoint="$MEDIA_BLOB_ENDPOINT"
export TF_VAR_aoai_endpoint="$AOAI_ENDPOINT"
export TF_VAR_aoai_account_id="$AOAI_ACCOUNT_ID"
export TF_VAR_aoai_model_deployment="$AOAI_MODEL_DEPLOYMENT"
export TF_VAR_entra_tenant_name="$ENTRA_TENANT_NAME"
export TF_VAR_entra_tenant_id="$ENTRA_TENANT_ID"
export TF_VAR_entra_client_id="$ENTRA_CLIENT_ID"
export TF_VAR_web_origin="$WEB_BASE_URL"

terraform init -upgrade
terraform apply -auto-approve

cd "${SCRIPT_DIR}"


# ── Stage 2b: Deploy function code ────────────────────────────────────────────

echo "NOTE: Packaging and deploying function code..."
cd "${SCRIPT_DIR}/02-functions/code"

rm -f app.zip
zip -r app.zip . \
  -x "*.git*" \
  -x "*__pycache__*" \
  -x "*.pytest_cache*" \
  -x "*.DS_Store"

FUNC_APP_NAME=$(az functionapp list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?starts_with(name, 'resume-func-')].name" \
  --output tsv)

# SCM site can take a minute to initialize after Terraform creates the app
_DEPLOY_MAX=10
_DEPLOY_DELAY=30
for _attempt in $(seq 1 $_DEPLOY_MAX); do
  if az functionapp deployment source config-zip \
    --name "$FUNC_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --src app.zip \
    --build-remote true; then
    break
  fi
  if [[ $_attempt -lt $_DEPLOY_MAX ]]; then
    echo "NOTE: Deployment failed (attempt ${_attempt}/${_DEPLOY_MAX}). Retrying in ${_DEPLOY_DELAY}s..."
    sleep $_DEPLOY_DELAY
  else
    echo "ERROR: Function code deployment failed after ${_DEPLOY_MAX} attempts."
    exit 1
  fi
done

cd "${SCRIPT_DIR}"

API_BASE="https://$(az functionapp show \
  --name "$FUNC_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.defaultHostName" \
  -o tsv)/api"

echo "NOTE: Function app: ${FUNC_APP_NAME}"
echo "NOTE: API base:     ${API_BASE}"


# ── Stage 3: Web app ──────────────────────────────────────────────────────────

echo "NOTE: Generating frontend config..."

REDIRECT_URI="${WEB_BASE_URL}callback.html"

# ES module config read by auth.js and api.js
export ENTRA_AUTHORITY ENTRA_CLIENT_ID REDIRECT_URI API_BASE_URL="${API_BASE}"
envsubst < "${SCRIPT_DIR}/03-webapp/site/js/config.js.tmpl" \
         > "${SCRIPT_DIR}/03-webapp/site/js/config.js"

# JSON config read by callback.html during PKCE code exchange
cat > "${SCRIPT_DIR}/03-webapp/site/config.json" <<EOF
{
  "authority":   "${ENTRA_AUTHORITY}",
  "clientId":    "${ENTRA_CLIENT_ID}",
  "redirectUri": "${REDIRECT_URI}",
  "apiBaseUrl":  "${API_BASE}"
}
EOF

echo "NOTE: Deploying web app..."
cd "${SCRIPT_DIR}/03-webapp"
terraform init -upgrade
terraform apply -auto-approve -var="web_storage_name=${WEB_STORAGE_NAME}"

WEBSITE_URL=$(terraform output -raw website_url)
cd "${SCRIPT_DIR}"

echo ""
echo "NOTE: Deployment complete."
echo "NOTE: API:     ${API_BASE}"
echo "NOTE: Web app: ${WEBSITE_URL}index.html"
echo ""

"${SCRIPT_DIR}/validate.sh"
