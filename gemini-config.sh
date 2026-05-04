#!/usr/bin/env bash
# ================================================================================
# gemini-config.sh
# Single source of truth for the Vertex AI Gemini model used by the worker.
# Sourced by apply.sh, destroy.sh, and check_env.sh so all scripts agree.
# ================================================================================
export GEMINI_MODEL_ID="gemini-2.5-flash"
