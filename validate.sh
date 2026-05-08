#!/usr/bin/env bash
# ================================================================================
# validate.sh
# Post-deploy summary: prints the Function App API URL and the SPA web URL.
# ================================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ================================================================================
# Read Terraform Outputs
# ================================================================================

WEBSITE_URL=$(cd "${SCRIPT_DIR}/03-webapp" && terraform output -raw website_url 2>/dev/null || true)
FUNC_APP_URL=$(cd "${SCRIPT_DIR}/02-functions" && terraform output -raw function_app_url 2>/dev/null || true)

if [[ -z "${FUNC_APP_URL}" ]]; then
  echo "ERROR: Could not read 'function_app_url' from 02-functions."
  echo "       Run './apply.sh' first."
  exit 1
fi

if [[ -z "${WEBSITE_URL}" ]]; then
  echo "ERROR: Could not read 'website_url' from 03-webapp."
  echo "       Run './apply.sh' first."
  exit 1
fi

echo ""
echo "================================================================================="
echo "  Resume Scorer — Deployment validated!"
echo "================================================================================="
echo "  Web : ${WEBSITE_URL}index.html"
echo "================================================================================="
echo ""
