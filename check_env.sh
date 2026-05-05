#!/usr/bin/env bash
# ================================================================================
# check_env.sh
# Validates local tooling, Azure credentials, and Entra External ID connectivity
# before apply.sh or destroy.sh are allowed to proceed.
# ================================================================================
set -euo pipefail

# ================================================================================
# Tool Validation
# ================================================================================

echo "NOTE: Validating that required commands are found in your PATH."

commands=("az" "terraform" "jq" "zip" "envsubst")

all_found=true

for cmd in "${commands[@]}"; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: $cmd is not found in the current PATH."
    all_found=false
  else
    echo "NOTE: $cmd is found in the current PATH."
  fi
done

if [ "$all_found" = true ]; then
  echo "NOTE: All required commands are available."
else
  echo "ERROR: One or more commands are missing."
  exit 1
fi

# ================================================================================
# Environment Variables
# ================================================================================

echo "NOTE: Validating that required environment variables are set."

required_vars=(
  "ARM_CLIENT_ID"
  "ARM_CLIENT_SECRET"
  "ARM_SUBSCRIPTION_ID"
  "ARM_TENANT_ID"
  "ENTRA_TENANT_ID"
  "ENTRA_TENANT_NAME"
  "ENTRA_SP_CLIENT_ID"
  "ENTRA_SP_CLIENT_SECRET"
  "ENTRA_USER_FLOW_NAME"
)

all_set=true

for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set or is empty."
    all_set=false
  else
    echo "NOTE: $var is set."
  fi
done

if [ "$all_set" = true ]; then
  echo "NOTE: All required environment variables are set."
else
  echo "ERROR: One or more required environment variables are missing or empty."
  exit 1
fi

# ================================================================================
# Azure Login
# ================================================================================

echo "NOTE: Logging in to Azure using Service Principal..."
az login --service-principal \
  --username "$ARM_CLIENT_ID" \
  --password "$ARM_CLIENT_SECRET" \
  --tenant   "$ARM_TENANT_ID" > /dev/null 2>&1

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to log into Azure. Please check your credentials."
  exit 1
else
  echo "NOTE: Successfully logged into Azure."
fi

# ================================================================================
# Entra External ID Validation
# Verifies the service principal can reach Graph API and the user flow exists.
# ================================================================================

echo "NOTE: Validating Entra External ID credentials and user flow..."

_validate_entra() {
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
    echo "WARNING: User flow '${ENTRA_USER_FLOW_NAME}' not found in tenant '${ENTRA_TENANT_NAME}'."
    return 1
  fi

  echo "NOTE: Entra service principal credentials are valid."
  echo "NOTE: User flow '${ENTRA_USER_FLOW_NAME}' found (id: ${FLOW_ID})."
}

_GRAPH_MAX=10
_GRAPH_DELAY=30
for _attempt in $(seq 1 $_GRAPH_MAX); do
  if _validate_entra; then
    break
  fi
  if [[ $_attempt -lt $_GRAPH_MAX ]]; then
    echo "NOTE: Retrying in ${_GRAPH_DELAY}s (attempt ${_attempt}/${_GRAPH_MAX})..."
    sleep $_GRAPH_DELAY
  else
    echo "ERROR: Entra validation failed after ${_GRAPH_MAX} attempts."
    echo "       Check ENTRA_SP_CLIENT_ID, ENTRA_SP_CLIENT_SECRET, and ENTRA_USER_FLOW_NAME."
    exit 1
  fi
done
