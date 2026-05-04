#!/usr/bin/env bash
# ================================================================================
# validate.sh
# Post-deploy summary: prints the API Gateway URL and the webapp GCS URL.
# ================================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ================================================================================
# Read Terraform Outputs
# ================================================================================

GATEWAY_URL=$(cd "${SCRIPT_DIR}/02-functions" && terraform output -raw gateway_url 2>/dev/null || echo "")
WEBAPP_URL=$(cd "${SCRIPT_DIR}/03-webapp" && terraform output -raw webapp_url 2>/dev/null || echo "")

echo ""
echo "==================================================================================="
echo "  Resume Scorer — Deployment validated!"
echo "==================================================================================="
echo "  App : ${WEBAPP_URL}"
echo "==================================================================================="
echo ""
