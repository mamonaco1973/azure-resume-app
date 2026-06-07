# ================================================================================
# function_app.py — Azure Resume Scorer
#
# Purpose
# Single Azure Functions app containing all HTTP API routes and the Service Bus
# queue trigger worker. Replaces the separate GCP Cloud Functions (api + worker).
#
# Key Responsibilities
# - HTTP routes: resume CRUD + job CRUD + folder CRUD + attachment CRUD
# - GET /usage — per-user AOAI token consumption tracking
# - JWT validation against Entra External ID JWKS (cached per warm instance)
# - Cosmos DB operations for resume, job, folder, and user metadata
# - Blob Storage operations for resume text, job artifacts, and attachments
# - Service Bus message publishing (job submission)
# - Service Bus queue trigger: 2-phase Azure OpenAI scoring pipeline
#   with atomic token usage accumulation
# ================================================================================

import base64
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

import azure.functions as func
import jwt
import requests
from azure.cosmos import CosmosClient, exceptions as cosmos_exc
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.storage.blob import BlobServiceClient
from bs4 import BeautifulSoup
from jwt.algorithms import RSAAlgorithm
from openai import AzureOpenAI

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

# ================================================================================
# Configuration (injected by Terraform via Function App settings)
# ================================================================================

COSMOS_ENDPOINT            = os.environ["COSMOS_ENDPOINT"]
COSMOS_DATABASE            = os.environ["COSMOS_DATABASE_NAME"]
COSMOS_RESUMES_CONTAINER   = os.environ["COSMOS_RESUMES_CONTAINER"]
COSMOS_JOBS_CONTAINER      = os.environ["COSMOS_JOBS_CONTAINER"]
COSMOS_FOLDERS_CONTAINER   = os.environ["COSMOS_FOLDERS_CONTAINER"]
COSMOS_USERS_CONTAINER     = os.environ["COSMOS_USERS_CONTAINER"]

MEDIA_BLOB_ENDPOINT = os.environ["MEDIA_BLOB_ENDPOINT"]

AOAI_ENDPOINT         = os.environ["AOAI_ENDPOINT"]
AOAI_MODEL_DEPLOYMENT = os.environ["AOAI_MODEL_DEPLOYMENT"]

ENTRA_TENANT      = os.environ["ENTRA_TENANT_NAME"]
ENTRA_TENANT_ID   = os.environ["ENTRA_TENANT_ID"]
CLIENT_ID         = os.environ["ENTRA_CLIENT_ID"]

SB_NAMESPACE_FQDN = os.environ["SERVICEBUS_NAMESPACE_FQDN"]
SB_QUEUE_NAME     = os.environ["SERVICEBUS_QUEUE_NAME"]

# ================================================================================
# Constants
# ================================================================================

JOB_RETENTION_DAYS   = 90
TOKEN_LIMIT_DEFAULT  = 100_000
USER_LIMIT           = 100
ATTACHMENT_MAX_FILES = 5
ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024  # 10 MB

# ================================================================================
# Auth — Entra External ID JWT validation
# JWKS is cached per warm instance to avoid repeated network calls.
# ================================================================================

_jwks_cache = None


def _get_jwks():
    """Fetch the Entra External ID public key set, cached per instance.

    Uses ciamlogin.com — no policy name suffix is needed in the discovery URL.

    Returns:
        A dict containing the JWKS key set from the Entra discovery endpoint.
    """
    global _jwks_cache
    if _jwks_cache is None:
        url = (
            f"https://{ENTRA_TENANT}.ciamlogin.com/{ENTRA_TENANT_ID}"
            f"/discovery/v2.0/keys"
        )
        _jwks_cache = requests.get(url, timeout=5).json()
    return _jwks_cache


def validate_token(req: func.HttpRequest):
    """Return the owner ID (sub claim) if the Bearer token is valid, else None.

    Validates the RS256 signature against the Entra JWKS, then checks that
    the audience matches the registered client ID.

    Args:
        req: The incoming Azure Functions HTTP request.

    Returns:
        A string owner ID if valid, or None if missing or invalid.
    """
    auth = req.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None
    token = auth[7:]
    try:
        jwks = _get_jwks()
        header = jwt.get_unverified_header(token)
        key_data = next(
            (k for k in jwks["keys"] if k["kid"] == header["kid"]), None
        )
        if key_data is None:
            logging.warning(
                "validate_token: kid=%s not found in JWKS", header.get("kid")
            )
            return None
        public_key = RSAAlgorithm.from_jwk(json.dumps(key_data))
        claims = jwt.decode(
            token,
            public_key,
            algorithms=["RS256"],
            audience=CLIENT_ID,
        )
        return claims.get("sub") or claims.get("oid")
    except Exception as exc:
        logging.warning("validate_token failed: %s", exc)
        return None


# ================================================================================
# Azure service clients
# All clients use DefaultAzureCredential (managed identity in production).
# ================================================================================

def _get_cosmos_container(container_name: str):
    """Return a Cosmos DB container client authenticated via managed identity.

    Args:
        container_name: The container name (resumes, jobs, folders, or users).

    Returns:
        A ContainerProxy for the specified container.
    """
    credential = DefaultAzureCredential()
    client = CosmosClient(COSMOS_ENDPOINT, credential=credential)
    return (
        client
        .get_database_client(COSMOS_DATABASE)
        .get_container_client(container_name)
    )


def _get_blob_service() -> BlobServiceClient:
    """Return a BlobServiceClient authenticated via managed identity."""
    return BlobServiceClient(
        account_url=MEDIA_BLOB_ENDPOINT,
        credential=DefaultAzureCredential(),
    )


_aoai_client = None


def _get_aoai_client() -> AzureOpenAI:
    """Return an AzureOpenAI client authenticated via managed identity.

    Cached per warm instance — token provider handles refresh internally.

    Returns:
        An AzureOpenAI client pointed at the configured endpoint.
    """
    global _aoai_client
    if _aoai_client is None:
        token_provider = get_bearer_token_provider(
            DefaultAzureCredential(),
            "https://cognitiveservices.azure.com/.default",
        )
        _aoai_client = AzureOpenAI(
            azure_endpoint=AOAI_ENDPOINT,
            azure_ad_token_provider=token_provider,
            api_version="2024-12-01-preview",
        )
    return _aoai_client


# ================================================================================
# Helpers
# ================================================================================

def _resp(status: int, body) -> func.HttpResponse:
    """Serialize body as JSON and return an HttpResponse."""
    return func.HttpResponse(
        json.dumps(body),
        status_code=status,
        mimetype="application/json",
        headers={"Content-Type": "application/json"},
    )


def _now_iso() -> str:
    """Return the current UTC time as an ISO 8601 string."""
    return datetime.now(timezone.utc).isoformat()


def _make_id() -> str:
    """Return a random hex ID."""
    return uuid.uuid4().hex


def _blob_text(blob_service: BlobServiceClient, container: str, path: str) -> str:
    """Download a blob as text, returning empty string if it does not exist.

    Args:
        blob_service: An authenticated BlobServiceClient.
        container: Container name.
        path: Blob path within the container.

    Returns:
        Blob content as a string, or empty string if not found.
    """
    try:
        return (
            blob_service
            .get_blob_client(container, path)
            .download_blob()
            .readall()
            .decode("utf-8", errors="replace")
        )
    except Exception:
        return ""


def _upload_blob(
    blob_service: BlobServiceClient, container: str, path: str, text: str
) -> None:
    """Upload a UTF-8 text string to blob storage, overwriting if present.

    Args:
        blob_service: An authenticated BlobServiceClient.
        container: Container name.
        path: Blob path within the container.
        text: Content to upload.
    """
    blob_service.get_blob_client(container, path).upload_blob(
        text.encode("utf-8"),
        overwrite=True,
        content_settings=None,
    )


def _upload_blob_bytes(
    blob_service: BlobServiceClient,
    container: str,
    path: str,
    data: bytes,
    content_type: str = "application/octet-stream",
) -> None:
    """Upload raw bytes to blob storage, overwriting if present.

    Args:
        blob_service: An authenticated BlobServiceClient.
        container: Container name.
        path: Blob path within the container.
        data: Raw bytes to upload.
        content_type: MIME type for the blob.
    """
    from azure.storage.blob import ContentSettings
    blob_service.get_blob_client(container, path).upload_blob(
        data,
        overwrite=True,
        content_settings=ContentSettings(content_type=content_type),
    )


def _download_blob_bytes(
    blob_service: BlobServiceClient, container: str, path: str
) -> bytes:
    """Download a blob as raw bytes.

    Args:
        blob_service: An authenticated BlobServiceClient.
        container: Container name.
        path: Blob path within the container.

    Returns:
        Raw bytes, or empty bytes if not found.
    """
    try:
        return (
            blob_service
            .get_blob_client(container, path)
            .download_blob()
            .readall()
        )
    except Exception:
        return b""


def _delete_blob(
    blob_service: BlobServiceClient, container: str, path: str
) -> None:
    """Delete a blob, ignoring errors if it does not exist.

    Args:
        blob_service: An authenticated BlobServiceClient.
        container: Container name.
        path: Blob path within the container.
    """
    try:
        blob_service.get_blob_client(container, path).delete_blob()
    except Exception:
        pass


def _delete_blob_prefix(
    blob_service: BlobServiceClient, container: str, prefix: str
) -> None:
    """Delete all blobs whose path starts with prefix.

    Used to clean up all attachments for a job on delete.

    Args:
        blob_service: An authenticated BlobServiceClient.
        container: Container name.
        prefix: Path prefix to match.
    """
    try:
        container_client = blob_service.get_container_client(container)
        for blob in container_client.list_blobs(name_starts_with=prefix):
            try:
                container_client.delete_blob(blob.name)
            except Exception:
                pass
    except Exception:
        pass


# ================================================================================
# Resume Routes
# ================================================================================

@app.route(route="resumes", methods=["GET"])
def list_resumes(req: func.HttpRequest) -> func.HttpResponse:
    """List all resumes for the authenticated user, newest first."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    container = _get_cosmos_container(COSMOS_RESUMES_CONTAINER)
    items = list(container.query_items(
        query=(
            "SELECT * FROM c WHERE c.owner = @owner "
            "ORDER BY c.created_at DESC"
        ),
        parameters=[{"name": "@owner", "value": owner}],
        enable_cross_partition_query=False,
    ))

    return _resp(200, [
        {
            "resume_id":  item["resume_id"],
            "name":       item.get("name", ""),
            "created_at": item.get("created_at"),
            "updated_at": item.get("updated_at"),
        }
        for item in items
    ])


@app.route(route="resumes", methods=["POST"])
def create_resume(req: func.HttpRequest) -> func.HttpResponse:
    """Create a new resume — saves text to Blob Storage and metadata to Cosmos."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    try:
        body = req.get_json()
    except ValueError:
        return _resp(400, {"error": "Invalid JSON"})

    name   = (body.get("name") or "").strip()
    resume = (body.get("resume") or "").strip()

    if not name:
        return _resp(400, {"error": "name is required"})
    if not resume:
        return _resp(400, {"error": "resume text is required"})

    resume_id = _make_id()
    blob_path = f"{owner}/{resume_id}.txt"
    now       = _now_iso()

    _upload_blob(_get_blob_service(), "resumes", blob_path, resume)

    doc = {
        "id":        f"{owner}_{resume_id}",
        "owner":     owner,
        "resume_id": resume_id,
        "name":      name,
        "blob_key":  f"resumes/{blob_path}",
        "created_at": now,
        "updated_at": now,
    }
    _get_cosmos_container(COSMOS_RESUMES_CONTAINER).create_item(body=doc)

    logging.info("Created resume owner=%s resume_id=%s", owner, resume_id)
    return _resp(201, {"resume_id": resume_id, "name": name})


@app.route(route="resumes/{resume_id}", methods=["GET"])
def get_resume(req: func.HttpRequest) -> func.HttpResponse:
    """Fetch a single resume with its text content."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    resume_id = req.route_params.get("resume_id", "")
    if not resume_id:
        return _resp(400, {"error": "Missing resume_id"})

    try:
        item = _get_cosmos_container(COSMOS_RESUMES_CONTAINER).read_item(
            item=f"{owner}_{resume_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    blob_path = f"{owner}/{resume_id}.txt"
    text = _blob_text(_get_blob_service(), "resumes", blob_path)

    return _resp(200, {
        "resume_id":  item["resume_id"],
        "name":       item.get("name", ""),
        "resume":     text,
        "created_at": item.get("created_at"),
        "updated_at": item.get("updated_at"),
    })


@app.route(route="resumes/{resume_id}", methods=["PUT"])
def update_resume(req: func.HttpRequest) -> func.HttpResponse:
    """Update a resume's name and/or text content."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    resume_id = req.route_params.get("resume_id", "")
    if not resume_id:
        return _resp(400, {"error": "Missing resume_id"})

    try:
        body = req.get_json()
    except ValueError:
        return _resp(400, {"error": "Invalid JSON"})

    name   = (body.get("name")   or "").strip()
    resume = (body.get("resume") or "").strip()

    if not name:
        return _resp(400, {"error": "name is required"})
    if not resume:
        return _resp(400, {"error": "resume text is required"})

    container = _get_cosmos_container(COSMOS_RESUMES_CONTAINER)
    try:
        container.read_item(
            item=f"{owner}_{resume_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    blob_path = f"{owner}/{resume_id}.txt"
    _upload_blob(_get_blob_service(), "resumes", blob_path, resume)

    now = _now_iso()
    container.patch_item(
        item=f"{owner}_{resume_id}",
        partition_key=owner,
        patch_operations=[
            {"op": "set", "path": "/name",       "value": name},
            {"op": "set", "path": "/updated_at", "value": now},
        ],
    )

    return _resp(200, {"resume_id": resume_id, "name": name})


@app.route(route="resumes/{resume_id}", methods=["DELETE"])
def delete_resume(req: func.HttpRequest) -> func.HttpResponse:
    """Delete a resume's blob and Cosmos document."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    resume_id = req.route_params.get("resume_id", "")
    if not resume_id:
        return _resp(400, {"error": "Missing resume_id"})

    container = _get_cosmos_container(COSMOS_RESUMES_CONTAINER)
    try:
        container.read_item(
            item=f"{owner}_{resume_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    _delete_blob(_get_blob_service(), "resumes", f"{owner}/{resume_id}.txt")
    container.delete_item(
        item=f"{owner}_{resume_id}", partition_key=owner
    )

    logging.info("Deleted resume owner=%s resume_id=%s", owner, resume_id)
    return _resp(200, {"resume_id": resume_id, "deleted": True})


# ================================================================================
# Folder Routes
# ================================================================================

@app.route(route="folders", methods=["GET"])
def list_folders(req: func.HttpRequest) -> func.HttpResponse:
    """List all folders for the authenticated user."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    container = _get_cosmos_container(COSMOS_FOLDERS_CONTAINER)
    items = list(container.query_items(
        query=(
            "SELECT * FROM c WHERE c.owner = @owner "
            "ORDER BY c.created_at ASC"
        ),
        parameters=[{"name": "@owner", "value": owner}],
        enable_cross_partition_query=False,
    ))

    return _resp(200, [
        {
            "folder_id":  item["folder_id"],
            "name":       item.get("name", ""),
            "created_at": item.get("created_at"),
        }
        for item in items
    ])


@app.route(route="folders", methods=["POST"])
def create_folder(req: func.HttpRequest) -> func.HttpResponse:
    """Create a new folder."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    try:
        body = req.get_json()
    except ValueError:
        return _resp(400, {"error": "Invalid JSON"})

    name = (body.get("name") or "").strip()
    if not name:
        return _resp(400, {"error": "name is required"})

    folder_id = _make_id()
    now       = _now_iso()

    doc = {
        "id":         f"{owner}_{folder_id}",
        "owner":      owner,
        "folder_id":  folder_id,
        "name":       name,
        "created_at": now,
    }
    _get_cosmos_container(COSMOS_FOLDERS_CONTAINER).create_item(body=doc)

    logging.info("Created folder owner=%s folder_id=%s", owner, folder_id)
    return _resp(201, {"folder_id": folder_id, "name": name})


@app.route(route="folders/{folder_id}", methods=["DELETE"])
def delete_folder(req: func.HttpRequest) -> func.HttpResponse:
    """Delete a folder. Jobs inside are unassigned (folder_id cleared)."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    folder_id = req.route_params.get("folder_id", "")
    if not folder_id:
        return _resp(400, {"error": "Missing folder_id"})

    container = _get_cosmos_container(COSMOS_FOLDERS_CONTAINER)
    try:
        container.read_item(item=f"{owner}_{folder_id}", partition_key=owner)
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    container.delete_item(item=f"{owner}_{folder_id}", partition_key=owner)

    # Unassign all jobs in this folder
    jobs_container = _get_cosmos_container(COSMOS_JOBS_CONTAINER)
    affected = list(jobs_container.query_items(
        query=(
            "SELECT c.id, c.job_id FROM c "
            "WHERE c.owner = @owner AND c.folder_id = @folder_id"
        ),
        parameters=[
            {"name": "@owner",     "value": owner},
            {"name": "@folder_id", "value": folder_id},
        ],
        enable_cross_partition_query=False,
    ))
    for job in affected:
        try:
            jobs_container.patch_item(
                item=job["id"],
                partition_key=owner,
                patch_operations=[{"op": "set", "path": "/folder_id", "value": None}],
            )
        except Exception:
            pass

    logging.info("Deleted folder owner=%s folder_id=%s", owner, folder_id)
    return _resp(200, {"folder_id": folder_id, "deleted": True})


# ================================================================================
# Job Routes
# ================================================================================

@app.route(route="jobs", methods=["GET"])
def list_jobs(req: func.HttpRequest) -> func.HttpResponse:
    """List all jobs for the authenticated user, newest first."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    container = _get_cosmos_container(COSMOS_JOBS_CONTAINER)
    items = list(container.query_items(
        query=(
            "SELECT TOP 100 * FROM c WHERE c.owner = @owner "
            "ORDER BY c.created_at DESC"
        ),
        parameters=[{"name": "@owner", "value": owner}],
        enable_cross_partition_query=False,
    ))

    return _resp(200, [
        {
            "job_id":           item["job_id"],
            "resume_id":        item.get("resume_id"),
            "resume_name":      item.get("resume_name"),
            "folder_id":        item.get("folder_id"),
            "status":           item.get("status"),
            "score":            item.get("score"),
            "job_title":        item.get("job_title"),
            "company":          item.get("company_name"),
            "source_type":      item.get("source_type"),
            "job_url":          item.get("source_url"),
            "created_at":       item.get("created_at"),
            "attachment_count": len(item.get("attachments") or []),
        }
        for item in items
    ])


@app.route(route="jobs", methods=["POST"])
def create_job(req: func.HttpRequest) -> func.HttpResponse:
    """Submit a new scoring job.

    Looks up the resume, saves a snapshot to Blob Storage, publishes a
    Service Bus message, and creates a Cosmos DB job document.
    """
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    try:
        body = req.get_json()
    except ValueError:
        return _resp(400, {"error": "Invalid JSON"})

    resume_id       = (body.get("resume_id") or "").strip()
    source_type     = (body.get("source_type") or "url").strip()
    source_url      = (body.get("job_url") or "").strip()
    job_description = (body.get("job_description") or "").strip()
    folder_id       = (body.get("folder_id") or "").strip() or None

    if not resume_id:
        return _resp(400, {"error": "resume_id is required"})
    if source_type not in ("url", "raw_text"):
        return _resp(400, {"error": "source_type must be 'url' or 'raw_text'"})
    if source_type == "url" and not source_url:
        return _resp(400, {"error": "job_url is required for source_type=url"})
    if source_type == "raw_text" and not job_description:
        return _resp(
            400, {"error": "job_description is required for source_type=raw_text"}
        )

    # Enforce token cap before queuing the job
    usage = _get_usage_doc(owner)
    if usage.get("tokens_used", 0) >= usage.get("token_limit", TOKEN_LIMIT_DEFAULT):
        return _resp(429, {"error": "token_limit_exceeded"})

    # Load resume metadata and text
    try:
        resume_doc = _get_cosmos_container(COSMOS_RESUMES_CONTAINER).read_item(
            item=f"{owner}_{resume_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Resume not found"})

    blob_service  = _get_blob_service()
    resume_text   = _blob_text(blob_service, "resumes", f"{owner}/{resume_id}.txt")
    resume_name   = resume_doc.get("name", "")

    job_id = _make_id()
    base   = f"{owner}/{job_id}"
    now    = _now_iso()

    # Save resume snapshot so the worker has a point-in-time copy
    _upload_blob(blob_service, "jobs", f"{base}/resume_snapshot.txt", resume_text)

    # Pre-save raw job text for raw_text submissions
    if source_type == "raw_text":
        _upload_blob(
            blob_service, "jobs", f"{base}/job_description.txt", job_description
        )

    # Publish job to Service Bus
    credential = DefaultAzureCredential()
    with ServiceBusClient(
        fully_qualified_namespace=SB_NAMESPACE_FQDN,
        credential=credential,
    ) as sb_client:
        with sb_client.get_queue_sender(queue_name=SB_QUEUE_NAME) as sender:
            sender.send_messages(ServiceBusMessage(json.dumps({
                "job_id":      job_id,
                "owner":       owner,
                "source_type": source_type,
                "source_url":  source_url,
            })))

    # Create job document
    doc = {
        "id":           f"{owner}_{job_id}",
        "owner":        owner,
        "job_id":       job_id,
        "resume_id":    resume_id,
        "resume_name":  resume_name,
        "folder_id":    folder_id,
        "source_type":  source_type,
        "source_url":   source_url,
        "status":       "submitted",
        "score":        None,
        "job_title":    None,
        "company_name": None,
        "attachments":  [],
        "created_at":   now,
    }
    _get_cosmos_container(COSMOS_JOBS_CONTAINER).create_item(body=doc)

    logging.info(
        "Submitted job_id=%s owner=%s source_type=%s", job_id, owner, source_type
    )
    return _resp(202, {"job_id": job_id, "status": "submitted"})


# Route ordering matters: sub-routes must be registered before the generic
# {job_id} route so Azure Functions matches them correctly.

@app.route(route="jobs/{job_id}/notes", methods=["PATCH"])
def update_job_notes(req: func.HttpRequest) -> func.HttpResponse:
    """Save or replace the notes blob for a job."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    job_id = req.route_params.get("job_id", "")
    if not job_id:
        return _resp(400, {"error": "Missing job_id"})

    try:
        body = req.get_json()
    except ValueError:
        return _resp(400, {"error": "Invalid JSON"})

    notes = body.get("notes") or ""

    # Verify ownership before writing
    try:
        _get_cosmos_container(COSMOS_JOBS_CONTAINER).read_item(
            item=f"{owner}_{job_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    _upload_blob(
        _get_blob_service(), "jobs", f"{owner}/{job_id}/notes.txt", notes
    )
    return _resp(200, {"job_id": job_id, "updated": True})


@app.route(route="jobs/{job_id}/folder", methods=["PATCH"])
def move_job_to_folder(req: func.HttpRequest) -> func.HttpResponse:
    """Assign or unassign a job to a folder."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    job_id = req.route_params.get("job_id", "")
    if not job_id:
        return _resp(400, {"error": "Missing job_id"})

    try:
        body = req.get_json()
    except ValueError:
        return _resp(400, {"error": "Invalid JSON"})

    folder_id = body.get("folder_id") or None

    container = _get_cosmos_container(COSMOS_JOBS_CONTAINER)
    try:
        container.read_item(item=f"{owner}_{job_id}", partition_key=owner)
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    container.patch_item(
        item=f"{owner}_{job_id}",
        partition_key=owner,
        patch_operations=[{"op": "set", "path": "/folder_id", "value": folder_id}],
    )
    return _resp(200, {"job_id": job_id, "folder_id": folder_id})


# ================================================================================
# Attachment Routes
# Attachments are stored as blobs at jobs/{owner}/{job_id}/attachments/{att_id}/
# and the metadata list is maintained on the job Cosmos document.
# Base64 JSON transfer avoids signed-URL and content-type complications.
# ================================================================================

@app.route(route="jobs/{job_id}/attachments", methods=["GET"])
def list_attachments(req: func.HttpRequest) -> func.HttpResponse:
    """List attachment metadata for a job."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    job_id = req.route_params.get("job_id", "")
    if not job_id:
        return _resp(400, {"error": "Missing job_id"})

    try:
        item = _get_cosmos_container(COSMOS_JOBS_CONTAINER).read_item(
            item=f"{owner}_{job_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    return _resp(200, item.get("attachments") or [])


@app.route(route="jobs/{job_id}/attachments", methods=["POST"])
def upload_attachment(req: func.HttpRequest) -> func.HttpResponse:
    """Upload a file attachment to a job (base64-encoded JSON body).

    Enforces a 5-file cap and 10 MB per-file limit.
    """
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    job_id = req.route_params.get("job_id", "")
    if not job_id:
        return _resp(400, {"error": "Missing job_id"})

    try:
        body = req.get_json()
    except ValueError:
        return _resp(400, {"error": "Invalid JSON"})

    filename     = (body.get("filename") or "").strip()
    content_type = (body.get("content_type") or "application/octet-stream").strip()
    data_b64     = (body.get("data") or "").strip()

    if not filename:
        return _resp(400, {"error": "filename is required"})
    if not data_b64:
        return _resp(400, {"error": "data is required"})

    try:
        raw_bytes = base64.b64decode(data_b64)
    except Exception:
        return _resp(400, {"error": "data must be valid base64"})

    if len(raw_bytes) > ATTACHMENT_MAX_BYTES:
        return _resp(413, {"error": "File exceeds 10 MB limit"})

    jobs_container = _get_cosmos_container(COSMOS_JOBS_CONTAINER)
    try:
        job_doc = jobs_container.read_item(
            item=f"{owner}_{job_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    attachments = list(job_doc.get("attachments") or [])
    if len(attachments) >= ATTACHMENT_MAX_FILES:
        return _resp(400, {"error": "Attachment limit reached (5 max)"})

    att_id   = _make_id()
    blob_key = f"{owner}/{job_id}/attachments/{att_id}/{filename}"
    now      = _now_iso()

    _upload_blob_bytes(_get_blob_service(), "jobs", blob_key, raw_bytes, content_type)

    attachments.append({
        "attachment_id": att_id,
        "filename":      filename,
        "content_type":  content_type,
        "size":          len(raw_bytes),
        "uploaded_at":   now,
    })

    jobs_container.patch_item(
        item=f"{owner}_{job_id}",
        partition_key=owner,
        patch_operations=[{"op": "set", "path": "/attachments", "value": attachments}],
    )

    logging.info(
        "Uploaded attachment job=%s att=%s size=%d", job_id, att_id, len(raw_bytes)
    )
    return _resp(201, {"attachment_id": att_id, "filename": filename})


@app.route(route="jobs/{job_id}/attachments/{attachment_id}", methods=["GET"])
def download_attachment(req: func.HttpRequest) -> func.HttpResponse:
    """Download an attachment as a base64-encoded JSON response."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    job_id        = req.route_params.get("job_id", "")
    attachment_id = req.route_params.get("attachment_id", "")
    if not job_id or not attachment_id:
        return _resp(400, {"error": "Missing job_id or attachment_id"})

    try:
        job_doc = _get_cosmos_container(COSMOS_JOBS_CONTAINER).read_item(
            item=f"{owner}_{job_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    attachments = job_doc.get("attachments") or []
    att = next((a for a in attachments if a["attachment_id"] == attachment_id), None)
    if not att:
        return _resp(404, {"error": "Attachment not found"})

    blob_key = f"{owner}/{job_id}/attachments/{attachment_id}/{att['filename']}"
    raw = _download_blob_bytes(_get_blob_service(), "jobs", blob_key)

    return _resp(200, {
        "attachment_id": attachment_id,
        "filename":      att["filename"],
        "content_type":  att.get("content_type", "application/octet-stream"),
        "data":          base64.b64encode(raw).decode("ascii"),
    })


@app.route(route="jobs/{job_id}/attachments/{attachment_id}", methods=["DELETE"])
def delete_attachment(req: func.HttpRequest) -> func.HttpResponse:
    """Delete an attachment blob and remove it from the job's metadata list."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    job_id        = req.route_params.get("job_id", "")
    attachment_id = req.route_params.get("attachment_id", "")
    if not job_id or not attachment_id:
        return _resp(400, {"error": "Missing job_id or attachment_id"})

    jobs_container = _get_cosmos_container(COSMOS_JOBS_CONTAINER)
    try:
        job_doc = jobs_container.read_item(
            item=f"{owner}_{job_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    attachments = list(job_doc.get("attachments") or [])
    att = next((a for a in attachments if a["attachment_id"] == attachment_id), None)
    if not att:
        return _resp(404, {"error": "Attachment not found"})

    blob_key = f"{owner}/{job_id}/attachments/{attachment_id}/{att['filename']}"
    _delete_blob(_get_blob_service(), "jobs", blob_key)

    # Read-modify-write to avoid list_remove equality fragility
    updated = [a for a in attachments if a["attachment_id"] != attachment_id]
    jobs_container.patch_item(
        item=f"{owner}_{job_id}",
        partition_key=owner,
        patch_operations=[{"op": "set", "path": "/attachments", "value": updated}],
    )

    return _resp(200, {"attachment_id": attachment_id, "deleted": True})


@app.route(route="jobs/{job_id}", methods=["GET"])
def get_job(req: func.HttpRequest) -> func.HttpResponse:
    """Fetch a job with all artifact text (analysis, description, resume, notes)."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    job_id = req.route_params.get("job_id", "")
    if not job_id:
        return _resp(400, {"error": "Missing job_id"})

    try:
        item = _get_cosmos_container(COSMOS_JOBS_CONTAINER).read_item(
            item=f"{owner}_{job_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    blob_service = _get_blob_service()
    base         = f"{owner}/{job_id}"

    return _resp(200, {
        "job_id":          item["job_id"],
        "resume_id":       item.get("resume_id"),
        "resume_name":     item.get("resume_name"),
        "folder_id":       item.get("folder_id"),
        "status":          item.get("status"),
        "status_message":  item.get("error_message"),
        "score":           item.get("score"),
        "job_title":       item.get("job_title"),
        "company":         item.get("company_name"),
        "source_type":     item.get("source_type"),
        "job_url":         item.get("source_url"),
        "created_at":      item.get("created_at"),
        "attachments":     item.get("attachments") or [],
        "job_analysis":    _blob_text(blob_service, "jobs", f"{base}/job_analysis.txt"),
        "job_description": _blob_text(blob_service, "jobs", f"{base}/job_description.txt"),
        "resume_snapshot": _blob_text(blob_service, "jobs", f"{base}/resume_snapshot.txt"),
        "notes":           _blob_text(blob_service, "jobs", f"{base}/notes.txt"),
    })


@app.route(route="jobs/{job_id}", methods=["DELETE"])
def delete_job(req: func.HttpRequest) -> func.HttpResponse:
    """Delete all job artifacts (including attachments) and the Cosmos document."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    job_id = req.route_params.get("job_id", "")
    if not job_id:
        return _resp(400, {"error": "Missing job_id"})

    container = _get_cosmos_container(COSMOS_JOBS_CONTAINER)
    try:
        container.read_item(
            item=f"{owner}_{job_id}", partition_key=owner
        )
    except cosmos_exc.CosmosResourceNotFoundError:
        return _resp(404, {"error": "Not found"})

    blob_service = _get_blob_service()
    base         = f"{owner}/{job_id}"

    for artifact in (
        "resume_snapshot.txt",
        "job_description.txt",
        "job_analysis.txt",
        "notes.txt",
    ):
        _delete_blob(blob_service, "jobs", f"{base}/{artifact}")

    # Delete all attachment blobs under the job prefix
    _delete_blob_prefix(blob_service, "jobs", f"{base}/attachments/")

    container.delete_item(item=f"{owner}_{job_id}", partition_key=owner)

    logging.info("Deleted job_id=%s owner=%s", job_id, owner)
    return _resp(200, {"job_id": job_id, "deleted": True})


# ================================================================================
# Register Route
# Enforces USER_LIMIT by counting distinct users before creating a new record.
# Returning users short-circuit immediately on the first read.
# ================================================================================

@app.route(route="register", methods=["POST"])
def register(req: func.HttpRequest) -> func.HttpResponse:
    """Register or verify the authenticated user against the cap.

    Idempotent: returns 200 if already registered, 201 if newly registered,
    or 403 if the USER_LIMIT has been reached.

    Returns:
        200 if the user already exists.
        201 if the user was just created.
        403 if the user cap is full.
    """
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    container = _get_cosmos_container(COSMOS_USERS_CONTAINER)

    # Returning user — skip the count query entirely
    try:
        container.read_item(item=f"{owner}_usage", partition_key=owner)
        return _resp(200, {"status": "ok"})
    except cosmos_exc.CosmosResourceNotFoundError:
        pass

    # New user — count all existing user docs before creating
    counts = list(container.query_items(
        query="SELECT VALUE COUNT(1) FROM c",
        enable_cross_partition_query=True,
    ))
    total = counts[0] if counts else 0
    if total >= USER_LIMIT:
        logging.warning("register: user cap reached (%d)", total)
        return _resp(403, {"error": "User limit reached"})

    doc = {
        "id":          f"{owner}_usage",
        "owner":       owner,
        "tokens_used": 0,
        "token_limit": TOKEN_LIMIT_DEFAULT,
    }
    container.create_item(body=doc)
    logging.info("register: new user owner=%s total=%d", owner, total + 1)
    return _resp(201, {"status": "created"})


# ================================================================================
# Usage Route
# ================================================================================

@app.route(route="usage", methods=["GET"])
def get_usage(req: func.HttpRequest) -> func.HttpResponse:
    """Return per-user AOAI token usage and limit."""
    owner = validate_token(req)
    if not owner:
        return _resp(401, {"error": "Unauthorized"})

    doc = _get_usage_doc(owner)
    return _resp(200, {
        "tokens_used":  doc.get("tokens_used", 0),
        "token_limit":  doc.get("token_limit", TOKEN_LIMIT_DEFAULT),
    })


# ================================================================================
# Usage helpers
# ================================================================================

def _get_usage_doc(owner: str) -> dict:
    """Fetch or lazily create the usage document for an owner.

    Args:
        owner: The user's sub claim (partition key).

    Returns:
        The usage document dict (tokens_used, token_limit).
    """
    container = _get_cosmos_container(COSMOS_USERS_CONTAINER)
    try:
        return container.read_item(item=f"{owner}_usage", partition_key=owner)
    except cosmos_exc.CosmosResourceNotFoundError:
        doc = {
            "id":          f"{owner}_usage",
            "owner":       owner,
            "tokens_used": 0,
            "token_limit": TOKEN_LIMIT_DEFAULT,
        }
        container.create_item(body=doc)
        return doc


def _accumulate_tokens(owner: str, token_count: int) -> None:
    """Atomically add token_count to the user's lifetime usage total.

    Uses patch_item with an "incr" operation so concurrent requests
    don't overwrite each other's updates.

    Args:
        owner:       The user's sub claim.
        token_count: Number of tokens to add.
    """
    _get_usage_doc(owner)  # ensure the doc exists before incrementing
    container = _get_cosmos_container(COSMOS_USERS_CONTAINER)
    try:
        container.patch_item(
            item=f"{owner}_usage",
            partition_key=owner,
            patch_operations=[{
                "op":    "incr",
                "path":  "/tokens_used",
                "value": token_count,
            }],
        )
    except Exception as exc:
        # Non-fatal — log and continue; usage tracking should never block scoring
        logging.warning("Failed to accumulate tokens owner=%s: %s", owner, exc)


# ================================================================================
# Scoring Prompts
# ================================================================================

_EXTRACTION_PROMPT = """\
Extract structured information from the job posting below.

Return ONLY valid JSON (no markdown fences) in this exact format:
{{
  "job_title":    "<short title, e.g. Senior Software Engineer>",
  "company_name": "<company name only, e.g. Acme Corp>",
  "job_text":     "<cleaned job description, max 3000 words — remove boilerplate, \
benefits, legal text>"
}}

Job posting:
---
{job_posting}
---
"""

_SCORING_PROMPT = """\
You are an expert resume reviewer. Score the resume against the job description \
on a scale of 0–100 and provide analysis.

Scoring guide:
  90–100  Exceptional match — nearly all requirements met
  70–89   Strong match — most requirements met, minor gaps
  50–69   Moderate match — some relevant experience, notable gaps
  30–49   Weak match — limited relevant experience, significant gaps
  0–29    Poor match — little to no relevant experience

Return ONLY valid JSON (no markdown fences) in this exact format:
{{
  "score":      <integer 0-100>,
  "strengths":  ["<strength 1>", "<strength 2>", "<strength 3>"],
  "weaknesses": ["<gap 1>", "<gap 2>", "<gap 3>"],
  "summary":    "<2-3 sentence overall assessment>"
}}

Job Title:   {job_title}
Company:     {company_name}

Job Description:
---
{job_text}
---

Resume:
---
{resume_text}
---
"""


# ================================================================================
# Service Bus queue trigger — resume scoring worker
# ================================================================================

@app.function_name(name="resume_scoring_worker")
@app.service_bus_queue_trigger(
    arg_name="msg",
    queue_name="%SERVICEBUS_QUEUE_NAME%",
    connection="ServiceBusConnection",
)
def resume_scoring_worker(msg: func.ServiceBusMessage) -> None:
    """Process a resume scoring job from the Service Bus queue.

    Fetches or reads the job posting, runs two Azure OpenAI calls to extract
    metadata then score the resume, writes artifacts to Blob Storage, updates
    the Cosmos DB job document, and atomically accumulates token usage.

    Raises on hard failure so the Service Bus SDK retries / dead-letters.
    Soft failures update status=Failed so the message is not redelivered.
    """
    raw  = msg.get_body().decode("utf-8")
    data = json.loads(raw)

    job_id      = data.get("job_id", "unknown")
    owner       = data.get("owner", "unknown")
    source_type = data.get("source_type", "url")
    source_url  = data.get("source_url", "")

    logging.info(
        "Worker: job=%s owner=%s source_type=%s", job_id, owner, source_type
    )

    jobs_container = _get_cosmos_container(COSMOS_JOBS_CONTAINER)

    def _update_job(**fields):
        jobs_container.patch_item(
            item=f"{owner}_{job_id}",
            partition_key=owner,
            patch_operations=[
                {"op": "set", "path": f"/{k}", "value": v}
                for k, v in fields.items()
            ],
        )

    try:
        _update_job(status="Scoring")

        blob_service = _get_blob_service()
        base         = f"{owner}/{job_id}"

        # Load the resume snapshot saved at job submission time
        resume_text = _blob_text(blob_service, "jobs", f"{base}/resume_snapshot.txt")

        # Obtain raw job text: fetch URL or read pre-saved blob
        if source_type == "url":
            raw_job_text = _fetch_url(source_url)
        else:
            raw_job_text = _blob_text(
                blob_service, "jobs", f"{base}/job_description.txt"
            )

        total_tokens = 0

        # --------------------------------------------------------------------
        # Phase 1: Extract job metadata and clean description
        # --------------------------------------------------------------------
        extraction_resp = _call_aoai(_EXTRACTION_PROMPT.format(
            job_posting=raw_job_text[:20000]
        ))
        total_tokens += extraction_resp["tokens"]
        extraction = _parse_json(extraction_resp["text"])

        job_title    = extraction.get("job_title", "")
        company_name = extraction.get("company_name", "")
        job_text     = extraction.get("job_text", raw_job_text[:20000])

        # Overwrite job_description.txt with the cleaned AOAI-extracted text
        _upload_blob(blob_service, "jobs", f"{base}/job_description.txt", job_text)

        # --------------------------------------------------------------------
        # Phase 2: Score resume against job
        # --------------------------------------------------------------------
        scoring_resp = _call_aoai(_SCORING_PROMPT.format(
            job_title=job_title,
            company_name=company_name,
            job_text=job_text[:10000],
            resume_text=resume_text[:10000],
        ))
        total_tokens += scoring_resp["tokens"]
        scoring = _parse_json(scoring_resp["text"])

        score      = int(scoring.get("score", 0))
        strengths  = scoring.get("strengths", [])
        weaknesses = scoring.get("weaknesses", [])
        summary    = scoring.get("summary", "")

        analysis_text = "\n".join([
            f"Score: {score}/100",
            f"Job Title: {job_title}",
            f"Company: {company_name}",
            "",
            "Summary:",
            summary,
            "",
            "Strengths:",
            *[f"- {s}" for s in strengths],
            "",
            "Weaknesses:",
            *[f"- {w}" for w in weaknesses],
        ])
        _upload_blob(blob_service, "jobs", f"{base}/job_analysis.txt", analysis_text)

        _update_job(
            status="Scored",
            job_title=job_title,
            company_name=company_name,
            score=score,
        )

        # Accumulate token usage after scoring completes
        if total_tokens > 0:
            _accumulate_tokens(owner, total_tokens)

        logging.info("Worker: completed job=%s score=%d tokens=%d",
                     job_id, score, total_tokens)

    except Exception as exc:
        logging.exception("Worker: failed job=%s: %s", job_id, exc)
        try:
            _update_job(status="Failed", error_message=str(exc)[:500])
        except Exception:
            pass
        # Re-raise so Service Bus retries on transient failures
        raise


# ================================================================================
# Worker helpers
# ================================================================================

def _fetch_url(url: str) -> str:
    """Fetch a URL and return visible text with scripts and styles stripped.

    Args:
        url: The URL to fetch.

    Returns:
        Plain text extracted from the HTML body, truncated at 50 000 chars.
    """
    resp = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=30)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, "html.parser")
    for tag in soup(["script", "style"]):
        tag.decompose()
    return soup.get_text(separator="\n", strip=True)[:50000]


def _call_aoai(prompt: str) -> dict:
    """Call Azure OpenAI chat completions with exponential backoff on 429.

    Returns both the response text and the total token count consumed so the
    worker can accumulate usage across both scoring phases.

    Args:
        prompt: The user message to send.

    Returns:
        Dict with "text" (str) and "tokens" (int).

    Raises:
        Exception: Re-raises after 4 failed attempts.
    """
    for attempt in range(4):
        try:
            response = _get_aoai_client().chat.completions.create(
                model=AOAI_MODEL_DEPLOYMENT,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.1,
                response_format={"type": "json_object"},
            )
            tokens = 0
            if response.usage:
                tokens = (response.usage.total_tokens or 0)
            return {
                "text":   response.choices[0].message.content.strip(),
                "tokens": tokens,
            }
        except Exception as exc:
            if "429" in str(exc) and attempt < 3:
                wait = 10 * (2 ** attempt)
                logging.warning(
                    "AOAI rate limited, retrying in %ss...", wait
                )
                time.sleep(wait)
            else:
                raise


def _parse_json(raw: str) -> dict:
    """Parse JSON from an AOAI response, stripping markdown fences if present.

    Args:
        raw: Raw string from the AOAI response.

    Returns:
        Parsed JSON as a dict.

    Raises:
        json.JSONDecodeError: If the string cannot be parsed after cleaning.
    """
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        cleaned = raw.lstrip("```json").lstrip("```").rstrip("```").strip()
        return json.loads(cleaned)
