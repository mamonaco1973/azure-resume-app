# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## What This App Does

GCP-based Resume Scoring Application. Users upload resumes and submit
job postings (URL, raw text, or LinkedIn job IDs); the app uses Vertex
AI Gemini to score resume-to-job compatibility (0--100) asynchronously.

## Deployment Commands

All deployment runs from the repo root:

``` bash
./apply.sh      # Full deploy: pip deps, Terraform 3-phase, uploads SPA to GCS
./destroy.sh    # Tear down entire stack (empties buckets, deletes Firestore docs)
./check_env.sh  # Validate tools, credentials.json, Vertex AI connectivity
./validate.sh   # Post-deploy: print gateway and webapp URLs
```

Python dependencies are installed into each Cloud Function source
directory directly:

``` bash
pip install -r 02-functions/code/api/requirements.txt    -t 02-functions/code/api/
pip install -r 02-functions/code/worker/requirements.txt -t 02-functions/code/worker/
```

There are no test or lint commands configured.

## Architecture

    01-backend/        # Terraform: SAs, IAM, GCS media bucket, Pub/Sub, Identity Platform key
    02-functions/      # Terraform: Cloud Functions 2nd Gen, API Gateway; Python source
      code/api/        # HTTP Cloud Function — resume + job CRUD
      code/worker/     # Eventarc/Pub/Sub Cloud Function — Gemini scoring pipeline
      openapi.yaml.tpl # API Gateway Swagger spec template
    03-webapp/         # Terraform: public GCS website bucket
      site/            # Vanilla JS SPA
        js/config.js.tmpl  # Config template populated by apply.sh at deploy time

### Request Flow

**Resume CRUD:** POST/GET/PUT/DELETE /resumes → API Gateway (JWT) →
resume-api CF2 → Firestore (metadata) + GCS (text content)

**Job scoring:**

1.  POST /jobs → API Gateway → resume-api CF2 → copies resume snapshot
    to GCS, publishes to Pub/Sub → returns job with `submitted` status
2.  resume-worker CF2 (Eventarc Pub/Sub trigger) → fetches URL if
    needed + strips HTML → Gemini 2-phase (extract metadata → score) →
    writes job_analysis.txt to GCS → updates Firestore with `Scored`
    status, score, job_title, company
3.  Frontend polls GET /jobs (5 s auto-refresh) to show updated scores

### Cloud Functions

-   **`code/api/main.py`** --- HTTP function; routes all CRUD by method
    + path segments; extracts owner from `X-Apigateway-Api-Userinfo`
-   **`code/worker/main.py`** --- Eventarc function; decodes Pub/Sub
    message; runs Gemini extraction + scoring pipeline

### Data Model (Firestore)

Collections: `resume_app_resumes`, `resume_app_jobs`
Document ID: `{owner_uid}_{resource_id}`

### GCS Layout (media bucket)

    users/{owner}/resumes/{resume_id}.txt
    users/{owner}/jobs/{job_id}/job_description.txt
    users/{owner}/jobs/{job_id}/resume_snapshot.txt
    users/{owner}/jobs/{job_id}/job_analysis.txt
    users/{owner}/jobs/{job_id}/notes.txt

### Key Terraform Variables (`02-functions/main.tf`)

-   `media_bucket_name` --- passed from 01-backend output
-   `gemini_model_id` --- passed from `gemini-config.sh` (default
    `gemini-2.0-flash-001`)

### Authentication

GCP Identity Platform (Firebase Auth) with email/password. In-page
sign-in modal — no redirect flow. Firebase JS SDK v11.1.0 loaded via
importmap. API Gateway validates Firebase JWTs via Swagger
`securityDefinitions` (`x-google-issuer`, `x-google-jwks_uri`).

### Frontend Config

`03-webapp/site/js/config.js.tmpl` is a template --- `apply.sh`
substitutes `FIREBASE_API_KEY`, `PROJECT_ID`, and `API_BASE_URL` at
deploy time to produce `config.js`. Never edit `config.js` directly.

## Changing the Gemini Model

Edit the single `export` line in `gemini-config.sh`:

```bash
export GEMINI_MODEL_ID="gemini-2.0-flash-001"
```

This flows to `check_env.sh` (pre-flight probe), the worker CF2
`GEMINI_MODEL_ID` env var via Terraform, and `code/worker/main.py` at
runtime. If the new model has a different response schema, also update
the prompt strings in `02-functions/code/worker/main.py`.

## Code Commenting Standards

Claude should apply consistent, professional commenting when modifying
code.

### General Rules

-   Keep comment lines **≤ 80 characters**
-   Do **not change code behavior**
-   Preserve existing variable names and structure
-   Comments should explain **intent**, not restate obvious code
-   Prefer concise, structured comments

### Python Files

Modules should begin with a structured header:

```python
# ================================================================================
# Module Name
#
# Purpose
# Brief explanation of what this module does.
#
# Key Responsibilities
# - Responsibility 1
# - Responsibility 2
# ================================================================================
```

Functions should include a short structured description:

```python
# --------------------------------------------------------------------------------
# Function: function_name
#
# Purpose
# Explain what the function does.
#
# Arguments
# - arg_name : description
#
# Returns
# - description
# --------------------------------------------------------------------------------
```

### Terraform Files

Use section banners to describe infrastructure blocks:

```hcl
# ================================================================================
# Section Name
# Description of resources created in this block
# ================================================================================
```

Comments should explain **why infrastructure exists**, not repeat the
resource definition.

### JavaScript Files

- Keep comment lines <= 80 characters
- Do not change UI behavior unless explicitly asked
- Preserve existing function names, IDs, and DOM structure
- Prefer concise section banners for major areas
- Use comments to explain intent, data flow, and UI behavior
- Do not add noisy comments for obvious one-line DOM operations
- Keep comments professional and compact
- Prefer small, reviewable diffs

Use section banners like:

```javascript
/* ================================================================================ */
/* Section Name */
/* Purpose of this section */
/* ================================================================================ */
```

For functions, use short block comments when helpful:

```javascript
/* -------------------------------------------------------------------------------- */
/* Function: functionName                                                            */
/* Purpose: Explain what this function does                                         */
/* -------------------------------------------------------------------------------- */
```

### Shell Scripts

- Keep comment lines <= 80 characters
- Preserve strict bash style: set -euo pipefail
- Use your quick start comment style
- Prefer bannered sections for each major operation
- Explain why a command block exists, not what obvious flags do
- Keep comments concise and operational
- Do not rewrite working command structure unless explicitly asked
- Preserve variable names unless a rename is necessary
- Prefer readable step-by-step execution flow
- Keep scripts idempotent where possible

Scripts should use section banners like:

```bash
# ================================================================================
# Section Name
# Purpose of this block
# ================================================================================
```

For smaller subsections:

```bash
# --------------------------------------------------------------------------------
# Subsection Name
# Brief operational note
# --------------------------------------------------------------------------------
```