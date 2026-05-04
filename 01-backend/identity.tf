# ================================================================================
# 01-backend/identity.tf
# Browser-safe API key scoped to Identity Platform only.
# Used by the SPA to initialise Firebase Auth without exposing project credentials.
# ================================================================================

resource "google_apikeys_key" "webapp_key" {
  provider = google-beta

  name         = "resume-webapp-key-${random_id.suffix.hex}"
  display_name = "Resume App Browser Key"

  restrictions {
    api_targets {
      service = "identitytoolkit.googleapis.com"
    }
  }
}

output "firebase_api_key" {
  value     = google_apikeys_key.webapp_key.key_string
  sensitive = true
}
