# ================================================================================
# 02-functions/functions.tf
# Cloud Functions (API + worker) and API Gateway.
# ================================================================================

# ================================================================================
# Function Source Packages
# ================================================================================

data "archive_file" "api_zip" {
  type        = "zip"
  source_dir  = "${path.module}/code/api"
  output_path = "${path.module}/api.zip"
}

data "archive_file" "worker_zip" {
  type        = "zip"
  source_dir  = "${path.module}/code/worker"
  output_path = "${path.module}/worker.zip"
}

resource "google_storage_bucket_object" "api_src" {
  name   = "api-${data.archive_file.api_zip.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.api_zip.output_path
}

resource "google_storage_bucket_object" "worker_src" {
  name   = "worker-${data.archive_file.worker_zip.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.worker_zip.output_path
}

# ================================================================================
# Worker Cloud Function (Pub/Sub-triggered via Eventarc)
# Handles async resume scoring; triggered by messages on the job-requests topic.
# ================================================================================

resource "google_cloudfunctions2_function" "worker" {
  name     = "resume-worker"
  location = "us-central1"

  build_config {
    runtime     = "python311"
    entry_point = "resume_worker"

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.worker_src.name
      }
    }
  }

  service_config {
    min_instance_count    = 0
    max_instance_count    = 5
    available_memory      = "512M"
    timeout_seconds       = 300
    service_account_email = data.google_service_account.worker_sa.email

    environment_variables = {
      GOOGLE_CLOUD_PROJECT = local.project_id
      MEDIA_BUCKET_NAME    = var.media_bucket_name
      GEMINI_MODEL_ID      = var.gemini_model_id
    }
  }

  event_trigger {
    trigger_region = "us-central1"
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = data.google_pubsub_topic.job_requests.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}

# ================================================================================
# API Cloud Function (HTTP)
# Single entry point for all /resumes and /jobs routes; routes internally.
# ================================================================================

resource "google_cloudfunctions2_function" "api" {
  name     = "resume-api"
  location = "us-central1"

  build_config {
    runtime     = "python311"
    entry_point = "resume_api"

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.api_src.name
      }
    }
  }

  service_config {
    min_instance_count    = 0
    max_instance_count    = 10
    available_memory      = "256M"
    timeout_seconds       = 60
    service_account_email = data.google_service_account.api_sa.email

    environment_variables = {
      GOOGLE_CLOUD_PROJECT = local.project_id
      MEDIA_BUCKET_NAME    = var.media_bucket_name
      JOBS_TOPIC           = data.google_pubsub_topic.job_requests.name
      CORS_ALLOW_ORIGIN    = "*"
    }
  }
}

# ================================================================================
# API Gateway
# Validates Firebase JWT before forwarding requests to the API function.
# ================================================================================

# Dedicated SA so the gateway can generate OIDC tokens to invoke the function
resource "google_service_account" "gateway_sa" {
  account_id   = "resume-gateway-sa"
  display_name = "Resume API Gateway Service Account"
}

resource "google_cloud_run_service_iam_member" "gateway_invoker" {
  project  = local.project_id
  location = "us-central1"
  service  = google_cloudfunctions2_function.api.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.gateway_sa.email}"
}

resource "google_api_gateway_api" "resume_api" {
  provider = google-beta
  api_id   = "resume-api-${random_id.suffix.hex}"
}

resource "google_api_gateway_api_config" "resume_api" {
  provider      = google-beta
  api           = google_api_gateway_api.resume_api.api_id
  api_config_id = "resume-config-${random_id.suffix.hex}"

  openapi_documents {
    document {
      path = "openapi.yaml"
      contents = base64encode(templatefile("${path.module}/openapi.yaml.tpl", {
        api_url    = google_cloudfunctions2_function.api.service_config[0].uri
        project_id = local.project_id
      }))
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_api_gateway_gateway" "resume_gateway" {
  provider   = google-beta
  api_config = google_api_gateway_api_config.resume_api.id
  gateway_id = "resume-gateway-${random_id.suffix.hex}"
  region     = "us-central1"
}

output "gateway_url" {
  value = "https://${google_api_gateway_gateway.resume_gateway.default_hostname}"
}

output "api_function_uri" {
  value = google_cloudfunctions2_function.api.service_config[0].uri
}
