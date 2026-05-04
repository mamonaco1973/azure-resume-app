# ================================================================================
# 01-backend/gcs.tf
# Private GCS bucket for all resume and job content stored server-side.
# The API and worker access this bucket directly; the frontend never touches it.
# ================================================================================

resource "google_storage_bucket" "media" {
  name          = "resume-media-${random_id.suffix.hex}"
  location      = "US"
  force_destroy = true

  uniform_bucket_level_access = true
}

# API SA needs full object access: creates snapshots, reads content, deletes jobs
resource "google_storage_bucket_iam_member" "api_gcs_admin" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.api_sa.email}"
}

# Worker SA needs full object access: reads snapshots, writes analyses, deletes
resource "google_storage_bucket_iam_member" "worker_gcs_admin" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.worker_sa.email}"
}

output "media_bucket_name" {
  value = google_storage_bucket.media.name
}
