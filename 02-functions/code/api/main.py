# ================================================================================
# api/main.py
#
# Purpose
# HTTP Cloud Function that serves as the single API entry point for the Resume
# Scorer application. Routes requests to resume and job handlers internally.
#
# Key Responsibilities
# - Extract the authenticated Firebase UID from the API Gateway header
# - CRUD operations for resumes (Firestore metadata + GCS content)
# - CRUD operations for jobs (Firestore metadata + GCS artifacts + Pub/Sub)
# - Return CORS headers on every response so the SPA can call the API
# ================================================================================

import base64
import json
import logging
import os
import uuid
from datetime import datetime, timezone

import functions_framework
from google.cloud import firestore, pubsub_v1, storage

logger = logging.getLogger(__name__)

PROJECT_ID   = os.environ["GOOGLE_CLOUD_PROJECT"]
MEDIA_BUCKET = os.environ["MEDIA_BUCKET_NAME"]
JOBS_TOPIC   = os.environ["JOBS_TOPIC"]
CORS_ORIGIN  = os.environ.get("CORS_ALLOW_ORIGIN", "*")

# Initialise clients once at cold-start; reused across warm invocations
db        = firestore.Client(project=PROJECT_ID)
publisher = pubsub_v1.PublisherClient()
gcs       = storage.Client(project=PROJECT_ID)
bucket    = gcs.bucket(MEDIA_BUCKET)
topic_path = publisher.topic_path(PROJECT_ID, JOBS_TOPIC)

# 90-day TTL — long enough that scored jobs remain available for reference
TTL_SECONDS = 90 * 24 * 3600


# ================================================================================
# Helpers
# ================================================================================

def _cors_headers():
    return {
        "Access-Control-Allow-Origin":  CORS_ORIGIN,
        "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Authorization, Content-Type",
        "Access-Control-Max-Age":       "3600",
    }


def _response(status, body):
    """Build a JSON response tuple with CORS headers."""
    return (
        json.dumps(body),
        status,
        {**_cors_headers(), "Content-Type": "application/json"},
    )


def _get_owner(request):
    """Extract Firebase UID from the base64-encoded header injected by API Gateway."""
    header = request.headers.get("X-Apigateway-Api-Userinfo", "")
    if not header:
        return None
    try:
        padded = header + "=" * (-len(header) % 4)
        claims = json.loads(base64.urlsafe_b64decode(padded))
        return claims.get("sub") or claims.get("user_id")
    except Exception:
        return None


def _now():
    return int(datetime.now(timezone.utc).timestamp())


def _ts_ms(epoch_seconds):
    """Convert epoch seconds to milliseconds for JavaScript Date compatibility."""
    return epoch_seconds * 1000 if epoch_seconds else 0


# ================================================================================
# Resume Handlers
# ================================================================================

def _handle_list_resumes(owner):
    docs = (
        db.collection("resume_app_resumes")
        .where("owner", "==", owner)
        .order_by("created_at", direction=firestore.Query.DESCENDING)
        .stream()
    )
    return _response(200, [
        {
            "resume_id":  d["resume_id"],
            "name":       d.get("name", ""),
            "created_at": _ts_ms(d.get("created_at")),
            "updated_at": _ts_ms(d.get("updated_at")),
        }
        for doc in docs
        for d in [doc.to_dict()]
    ])


def _handle_create_resume(owner, body):
    name    = (body.get("name")   or "").strip()
    content = (body.get("resume") or "").strip()
    if not name or not content:
        return _response(400, {"error": "name and resume are required"})

    resume_id = f"RESUME-{uuid.uuid4().hex[:12]}"
    gcs_key   = f"users/{owner}/resumes/{resume_id}.txt"
    now       = _now()

    bucket.blob(gcs_key).upload_from_string(content, content_type="text/plain")
    db.collection("resume_app_resumes").document(f"{owner}_{resume_id}").set({
        "owner":      owner,
        "resume_id":  resume_id,
        "name":       name,
        "gcs_key":    gcs_key,
        "created_at": now,
        "updated_at": now,
        "ttl":        now + TTL_SECONDS,
    })
    return _response(200, {"resume_id": resume_id, "name": name})


def _handle_get_resume(owner, resume_id):
    doc = db.collection("resume_app_resumes").document(f"{owner}_{resume_id}").get()
    if not doc.exists:
        return _response(404, {"error": "not found"})
    d = doc.to_dict()
    if d.get("owner") != owner:
        return _response(403, {"error": "forbidden"})

    content = bucket.blob(d["gcs_key"]).download_as_text()
    return _response(200, {
        "resume_id":  d["resume_id"],
        "name":       d.get("name", ""),
        "resume":     content,
        "created_at": _ts_ms(d.get("created_at")),
        "updated_at": _ts_ms(d.get("updated_at")),
    })


def _handle_update_resume(owner, resume_id, body):
    doc_ref = db.collection("resume_app_resumes").document(f"{owner}_{resume_id}")
    doc     = doc_ref.get()
    if not doc.exists:
        return _response(404, {"error": "not found"})
    d = doc.to_dict()
    if d.get("owner") != owner:
        return _response(403, {"error": "forbidden"})

    updates = {"updated_at": _now()}
    if "name" in body:
        updates["name"] = (body["name"] or "").strip()
    if "resume" in body:
        bucket.blob(d["gcs_key"]).upload_from_string(
            body["resume"], content_type="text/plain"
        )
    doc_ref.update(updates)
    return _response(200, {"resume_id": resume_id})


def _handle_delete_resume(owner, resume_id):
    doc_ref = db.collection("resume_app_resumes").document(f"{owner}_{resume_id}")
    doc     = doc_ref.get()
    if not doc.exists:
        return _response(404, {"error": "not found"})
    d = doc.to_dict()
    if d.get("owner") != owner:
        return _response(403, {"error": "forbidden"})

    bucket.blob(d["gcs_key"]).delete()
    doc_ref.delete()
    return _response(200, {"deleted": resume_id})


# ================================================================================
# Job Handlers
# ================================================================================

def _handle_list_jobs(owner):
    docs = (
        db.collection("resume_app_jobs")
        .where("owner", "==", owner)
        .order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(100)
        .stream()
    )
    return _response(200, [
        {
            "job_id":      d["job_id"],
            "resume_id":   d.get("resume_id", ""),
            "resume_name": d.get("resume_name", ""),
            "job_title":   d.get("job_title", ""),
            "company":     d.get("company_name", ""),
            "score":       d.get("score"),
            "status":      d.get("status", "submitted"),
            "created_at":  _ts_ms(d.get("created_at")),
        }
        for doc in docs
        for d in [doc.to_dict()]
    ])


def _handle_create_job(owner, body):
    resume_id   = (body.get("resume_id")    or "").strip()
    source_type = (body.get("source_type")  or "url").strip()
    source_url  = (body.get("job_url")      or "").strip()
    raw_text    = (body.get("job_description") or "").strip()

    if not resume_id:
        return _response(400, {"error": "resume_id is required"})
    if source_type == "url" and not source_url:
        return _response(400, {"error": "job_url required for url source_type"})
    if source_type == "raw_text" and not raw_text:
        return _response(400, {"error": "job_description required for raw_text source_type"})

    # Verify the resume exists and belongs to this user
    resume_doc = db.collection("resume_app_resumes").document(
        f"{owner}_{resume_id}"
    ).get()
    if not resume_doc.exists or resume_doc.to_dict().get("owner") != owner:
        return _response(404, {"error": "resume not found"})

    resume_data = resume_doc.to_dict()
    resume_name = resume_data.get("name", "")

    job_id = f"JOB-{uuid.uuid4().hex[:12]}"
    now    = _now()

    # Save a snapshot of the resume at submission time for the worker
    resume_content = bucket.blob(resume_data["gcs_key"]).download_as_text()
    bucket.blob(f"users/{owner}/jobs/{job_id}/resume_snapshot.txt").upload_from_string(
        resume_content, content_type="text/plain"
    )

    # For raw text jobs, pre-save the description for the worker to read
    if source_type == "raw_text":
        bucket.blob(f"users/{owner}/jobs/{job_id}/job_description.txt").upload_from_string(
            raw_text, content_type="text/plain"
        )

    db.collection("resume_app_jobs").document(f"{owner}_{job_id}").set({
        "owner":        owner,
        "job_id":       job_id,
        "resume_id":    resume_id,
        "resume_name":  resume_name,
        "source_type":  source_type,
        "source_url":   source_url if source_type == "url" else "",
        "job_title":    "",
        "company_name": "",
        "score":        None,
        "status":       "submitted",
        "created_at":   now,
        "ttl":          now + TTL_SECONDS,
    })

    publisher.publish(topic_path, json.dumps({
        "job_id":      job_id,
        "owner":       owner,
        "resume_id":   resume_id,
        "source_type": source_type,
        "source_url":  source_url,
    }).encode())

    return _response(200, {
        "job_id":    job_id,
        "resume_id": resume_id,
        "status":    "submitted",
    })


def _handle_get_job(owner, job_id):
    doc = db.collection("resume_app_jobs").document(f"{owner}_{job_id}").get()
    if not doc.exists:
        return _response(404, {"error": "not found"})
    d = doc.to_dict()
    if d.get("owner") != owner:
        return _response(403, {"error": "forbidden"})

    result = {
        "job_id":         d["job_id"],
        "resume_id":      d.get("resume_id", ""),
        "resume_name":    d.get("resume_name", ""),
        "job_title":      d.get("job_title", ""),
        "company":        d.get("company_name", ""),
        "score":          d.get("score"),
        "status":         d.get("status", "submitted"),
        "status_message": d.get("error_message", ""),
        "created_at":     _ts_ms(d.get("created_at")),
        "source_type":    d.get("source_type", ""),
        "job_url":        d.get("source_url", ""),
        "job_analysis":   "",
        "job_description": "",
        "resume_snapshot": "",
        "notes":          "",
    }

    # Load GCS artifacts when available; fail gracefully if any are missing
    base = f"users/{owner}/jobs/{job_id}"
    for field, key in [
        ("job_analysis",    f"{base}/job_analysis.txt"),
        ("job_description", f"{base}/job_description.txt"),
        ("resume_snapshot", f"{base}/resume_snapshot.txt"),
        ("notes",           f"{base}/notes.txt"),
    ]:
        try:
            result[field] = bucket.blob(key).download_as_text()
        except Exception:
            pass

    return _response(200, result)


def _handle_update_job_notes(owner, job_id, body):
    doc = db.collection("resume_app_jobs").document(f"{owner}_{job_id}").get()
    if not doc.exists:
        return _response(404, {"error": "not found"})
    if doc.to_dict().get("owner") != owner:
        return _response(403, {"error": "forbidden"})

    notes = body.get("notes") or ""
    bucket.blob(f"users/{owner}/jobs/{job_id}/notes.txt").upload_from_string(
        notes, content_type="text/plain"
    )
    return _response(200, {"job_id": job_id})


def _handle_delete_job(owner, job_id):
    doc_ref = db.collection("resume_app_jobs").document(f"{owner}_{job_id}")
    doc     = doc_ref.get()
    if not doc.exists:
        return _response(404, {"error": "not found"})
    d = doc.to_dict()
    if d.get("owner") != owner:
        return _response(403, {"error": "forbidden"})

    for blob in gcs.list_blobs(MEDIA_BUCKET, prefix=f"users/{owner}/jobs/{job_id}/"):
        blob.delete()
    doc_ref.delete()
    return _response(200, {"deleted": job_id})


# ================================================================================
# Entry Point
# ================================================================================

@functions_framework.http
def resume_api(request):
    """Route all API Gateway requests to the appropriate handler."""
    if request.method == "OPTIONS":
        return ("", 204, _cors_headers())

    owner = _get_owner(request)
    if not owner:
        return _response(401, {"error": "unauthorized"})

    path     = request.path.rstrip("/")
    method   = request.method.upper()
    segments = [s for s in path.split("/") if s]

    try:
        body = request.get_json(silent=True) or {}

        # /resumes
        if len(segments) == 1 and segments[0] == "resumes":
            if method == "GET":
                return _handle_list_resumes(owner)
            if method == "POST":
                return _handle_create_resume(owner, body)

        # /resumes/{id}
        if len(segments) == 2 and segments[0] == "resumes":
            rid = segments[1]
            if method == "GET":
                return _handle_get_resume(owner, rid)
            if method == "PUT":
                return _handle_update_resume(owner, rid, body)
            if method == "DELETE":
                return _handle_delete_resume(owner, rid)

        # /jobs
        if len(segments) == 1 and segments[0] == "jobs":
            if method == "GET":
                return _handle_list_jobs(owner)
            if method == "POST":
                return _handle_create_job(owner, body)

        # /jobs/{id}
        if len(segments) == 2 and segments[0] == "jobs":
            jid = segments[1]
            if method == "GET":
                return _handle_get_job(owner, jid)
            if method == "DELETE":
                return _handle_delete_job(owner, jid)

        # /jobs/{id}/notes
        if len(segments) == 3 and segments[0] == "jobs" and segments[2] == "notes":
            if method == "PATCH":
                return _handle_update_job_notes(owner, segments[1], body)

        return _response(404, {"error": "not found"})

    except Exception as exc:
        logger.exception("Unhandled error: %s", exc)
        return _response(500, {"error": "internal server error"})
