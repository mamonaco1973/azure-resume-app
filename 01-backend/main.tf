# ================================================================================
# 01-backend/main.tf
# Provider config, service accounts, and project-level IAM bindings.
# ================================================================================

terraform {
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 5.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.0" }
    random      = { source = "hashicorp/random",      version = "~> 3.0" }
  }
}

locals {
  credentials = jsondecode(file("${path.module}/../credentials.json"))
  project_id  = local.credentials.project_id
}

provider "google" {
  credentials = file("${path.module}/../credentials.json")
  project     = local.project_id
  region      = "us-central1"
}

provider "google-beta" {
  credentials = file("${path.module}/../credentials.json")
  project     = local.project_id
  region      = "us-central1"
}

provider "random" {}

resource "random_id" "suffix" {
  byte_length = 4
}

# ================================================================================
# Service Accounts
# ================================================================================

resource "google_service_account" "api_sa" {
  account_id   = "resume-api-sa"
  display_name = "Resume API Service Account"
}

resource "google_service_account" "worker_sa" {
  account_id   = "resume-worker-sa"
  display_name = "Resume Worker Service Account"
}

# ================================================================================
# Project-Level IAM — API Service Account
# ================================================================================

resource "google_project_iam_member" "api_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.api_sa.email}"
}

resource "google_project_iam_member" "api_firestore" {
  project = local.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.api_sa.email}"
}

# ================================================================================
# Project-Level IAM — Worker Service Account
# ================================================================================

resource "google_project_iam_member" "worker_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.worker_sa.email}"
}

resource "google_project_iam_member" "worker_firestore" {
  project = local.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.worker_sa.email}"
}

resource "google_project_iam_member" "worker_aiplatform" {
  project = local.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.worker_sa.email}"
}

# ================================================================================
# Outputs consumed by 02-functions
# ================================================================================

output "project_id" {
  value = local.project_id
}

output "api_sa_email" {
  value = google_service_account.api_sa.email
}

output "worker_sa_email" {
  value = google_service_account.worker_sa.email
}

output "suffix" {
  value = random_id.suffix.hex
}
