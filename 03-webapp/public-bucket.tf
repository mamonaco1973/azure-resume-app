# ================================================================================
# 03-webapp/public-bucket.tf
# Public GCS bucket that serves the SPA as a static website.
# apply.sh uploads site files after Terraform creates the bucket.
# ================================================================================

resource "google_storage_bucket" "webapp" {
  name          = "resume-web-${random_id.suffix.hex}"
  location      = "US"
  force_destroy = true

  uniform_bucket_level_access = true

  website {
    main_page_suffix = "index.html"
    not_found_page   = "index.html"
  }
}

resource "google_storage_bucket_iam_member" "public_viewer" {
  bucket = google_storage_bucket.webapp.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

output "webapp_bucket" {
  value = google_storage_bucket.webapp.name
}

output "webapp_url" {
  value = "https://storage.googleapis.com/${google_storage_bucket.webapp.name}/index.html"
}
