# ================================================================================
# 03-webapp/main.tf
# Provider config for the frontend static site bucket.
# ================================================================================

terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
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

provider "random" {}

resource "random_id" "suffix" {
  byte_length = 4
}
