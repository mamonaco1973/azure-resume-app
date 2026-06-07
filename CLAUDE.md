# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## What This App Does

Azure-based Resume Scoring Application. Users upload resumes and submit
job postings (URL or raw text); the app uses Azure OpenAI GPT-4o to score
resume-to-job compatibility (0--100) asynchronously.

## Deployment Commands

All deployment runs from the repo root:

``` bash
./apply.sh      # Full deploy: 3-stage Terraform + SPA upload
./destroy.sh    # Tear down entire stack
./check_env.sh  # Validate tools, credentials, Entra connectivity
./validate.sh   # Post-deploy: print API and webapp URLs
```

There are no test or lint commands configured.

## Required Environment Variables

`check_env.sh` validates all of these before any Terraform runs:

```bash
# Azure service principal — Terraform azurerm provider
ARM_CLIENT_ID
ARM_CLIENT_SECRET
ARM_TENANT_ID
ARM_SUBSCRIPTION_ID

# Entra External ID tenant — azuread provider + Graph API user flow wiring
ENTRA_TENANT_ID
ENTRA_TENANT_NAME        # e.g. mytenant.onmicrosoft.com
ENTRA_SP_CLIENT_ID
ENTRA_SP_CLIENT_SECRET
ENTRA_USER_FLOW_NAME     # display name of the self-service sign-up flow
```

`aoai-config.sh` sets `AOAI_MODEL_DEPLOYMENT` (default `gpt-4o`) and is
sourced by `apply.sh` and `destroy.sh`.

## Architecture

    01-backend/        # Terraform: SB, Cosmos DB, Blob Storage, AOAI, Entra app
    02-functions/      # Terraform: Function App (FC1 Flex); Python source
      code/
        function_app.py  # HTTP routes (resumes + jobs CRUD) + SB trigger worker
        requirements.txt
        host.json
    03-webapp/         # Terraform: SPA asset upload to Blob Storage $web
      site/            # Vanilla JS SPA (Entra PKCE auth)
        js/config.js.tmpl  # Config template substituted by apply.sh

### Request Flow

**Resume CRUD:** POST/GET/PUT/DELETE /api/resumes → Function App (JWT) →
Cosmos DB (metadata) + Blob Storage (text content)

**Job scoring:**

1.  POST /api/jobs → Function App → saves resume snapshot to Blob Storage,
    publishes to Service Bus → returns job with `submitted` status
2.  resume_scoring_worker (Service Bus trigger) → fetches URL if needed
    + strips HTML → AOAI 2-phase (extract metadata → score) →
    writes job_analysis.txt to Blob Storage → updates Cosmos DB with
    `Scored` status, score, job_title, company_name
3.  Frontend polls GET /api/jobs (5 s auto-refresh) to show updated scores

### Function App

-   **`code/function_app.py`** --- Single file with all HTTP routes and
    the Service Bus queue trigger; JWT extracted from Bearer header;
    `sub` claim becomes the Cosmos DB partition key
-   Auth: JWT validated in code against Entra External ID JWKS (cached
    per warm instance); no API Gateway needed
-   **User cap:** `POST /register` enforces `USER_LIMIT = 100`; returning
    users short-circuit on a single Cosmos read; new users trigger a
    cross-partition `COUNT(1)` query; 403 if cap is full
-   **Token cap:** `POST /jobs` enforces `TOKEN_LIMIT_DEFAULT = 100 000`;
    429 returned when exceeded
-   **Token tracking:** `resume_scoring_worker` accumulates AOAI token
    usage via Cosmos `patch_item` with `"op": "incr"` after both phases
-   **Route ordering:** sub-routes (`/notes`, `/folder`, `/attachments`)
    decorated before the generic `/{job_id}` route to avoid Azure
    Functions routing ambiguity

### API Routes

| Route | Methods | Purpose |
|-------|---------|---------|
| `/register` | POST | User-cap enforcement (max 100 users) |
| `/resumes` | GET, POST | Resume list + create |
| `/resumes/{resume_id}` | GET, PUT, DELETE | Resume CRUD |
| `/jobs` | GET, POST | Job list + submit |
| `/jobs/{job_id}/notes` | PATCH | Update notes |
| `/jobs/{job_id}/folder` | PATCH | Move job to folder |
| `/jobs/{job_id}/attachments` | GET, POST | List + upload attachments |
| `/jobs/{job_id}/attachments/{att_id}` | GET, DELETE | Download + delete attachment |
| `/jobs/{job_id}` | GET, DELETE | Job detail + delete |
| `/folders` | GET, POST | Folder list + create |
| `/folders/{folder_id}` | DELETE | Delete folder (unassigns jobs) |
| `/usage` | GET | Per-user AOAI token usage |

### Data Model (Cosmos DB)

Database: `resume-app`

-   `resumes` container — partition key `/owner`; doc id `{owner}_{resume_id}`
-   `jobs` container    — partition key `/owner`; doc id `{owner}_{job_id}`;
    TTL 90 days; fields include `folder_id`, `attachments[]`,
    `attachment_count`
-   `folders` container — partition key `/owner`; no TTL
-   `users` container   — partition key `/owner`; doc id `{owner}_usage`;
    fields: `tokens_used`, `token_limit` (default 100 000);
    used for both per-user token cap and user-count cap (max 100 users)

### Blob Storage Layout (media account)

    resumes/{owner}/{resume_id}.txt
    jobs/{owner}/{job_id}/
      resume_snapshot.txt
      job_description.txt    (URL-fetched or raw text, then cleaned by AOAI)
      job_analysis.txt       (AOAI scoring result)
      notes.txt              (user annotations)
      attachments/{att_id}/{filename}   (user file attachments)

### Key Terraform Variables

-   `aoai_endpoint`         — from 01-backend output
-   `aoai_model_deployment` — from `aoai-config.sh` (default `gpt-4o`)

### Authentication

Microsoft Entra External ID (PKCE). Login button redirects to Entra hosted
UI — no inline email/password form. Token stored in sessionStorage after
code exchange in `callback.html`. API validates JWT against JWKS.

### Frontend Config

`03-webapp/site/js/config.js.tmpl` is a template — `apply.sh` substitutes
`ENTRA_AUTHORITY`, `ENTRA_CLIENT_ID`, `REDIRECT_URI`, and `API_BASE_URL`
at deploy time to produce `config.js`. Never edit `config.js` directly.
`callback.html` reads `config.json` (also generated by `apply.sh`).

## Changing the Azure OpenAI Model

Edit the single `export` line in `aoai-config.sh`:

```bash
export AOAI_MODEL_DEPLOYMENT="gpt-4o"
```

This flows to the worker's `AOAI_MODEL_DEPLOYMENT` env var via Terraform.
If the new model has a different response schema, also update the prompt
strings in `02-functions/code/function_app.py`.

## Code Commenting Standards

Claude should apply consistent, professional commenting when modifying code.

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

Functions should use Google-style docstrings.

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

Use section banners like:

```javascript
/* ================================================================================ */
/* Section Name                                                                      */
/* Purpose of this section                                                           */
/* ================================================================================ */
```

### Shell Scripts

- Keep comment lines <= 80 characters
- Preserve strict bash style: set -euo pipefail
- Prefer bannered sections for each major operation
- Explain why a command block exists, not what obvious flags do
