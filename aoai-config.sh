#!/usr/bin/env bash
# ================================================================================
# aoai-config.sh
# Single source of truth for the Azure OpenAI model deployment name.
# Sourced by apply.sh; flows to the Function App AOAI_MODEL_DEPLOYMENT env var.
# ================================================================================
export AOAI_MODEL_DEPLOYMENT="gpt-4o"
