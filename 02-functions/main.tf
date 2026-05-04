# ================================================================================
# 02-functions/main.tf
# Provider config, variables, and shared data sources.
# Service accounts and Pub/Sub topic are resolved by name from 01-backend output.
# ================================================================================

terraform {
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 5.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.0" }
    random      = { source = "hashicorp/random",      version = "~> 3.0" }
    archive     = { source = "hashicorp/archive",     version = "~> 2.0" }
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
provider "archive" {}

variable "media_bucket_name" {
  description = "Name of the GCS media bucket (output of 01-backend)"
  type        = string
}

variable "gemini_model_id" {
  description = "Vertex AI Gemini model ID for the worker function"
  type        = string
}

# Resolve service accounts created in 01-backend by name
data "google_service_account" "api_sa" {
  account_id = "resume-api-sa"
}

data "google_service_account" "worker_sa" {
  account_id = "resume-worker-sa"
}

# Resolve Pub/Sub topic created in 01-backend by name
data "google_pubsub_topic" "job_requests" {
  name = "resume-job-requests"
}

resource "random_id" "suffix" {
  byte_length = 4
}

# Ephemeral bucket for storing function source ZIPs during deployment
resource "google_storage_bucket" "source" {
  name          = "resume-src-${random_id.suffix.hex}"
  location      = "US"
  force_destroy = true

  uniform_bucket_level_access = true
}
