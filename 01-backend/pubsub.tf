# ================================================================================
# 01-backend/pubsub.tf
# Pub/Sub topic + subscription for async job scoring.
# The API publishes; the worker Cloud Function is triggered via Eventarc.
# DLQ captures messages that exhaust the 5-attempt retry policy.
# ================================================================================

data "google_project" "project" {}

resource "google_pubsub_topic" "job_requests" {
  name = "resume-job-requests"
}

resource "google_pubsub_topic" "job_requests_dlq" {
  name = "resume-job-requests-dlq"
}

resource "google_pubsub_subscription" "job_requests_sub" {
  name  = "resume-job-requests-sub"
  topic = google_pubsub_topic.job_requests.name

  # Must be >= worker function timeout (300s) to avoid duplicate processing
  ack_deadline_seconds = 300

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.job_requests_dlq.id
    max_delivery_attempts = 5
  }
}

# Allow the Pub/Sub service agent to forward failed messages to the DLQ topic
resource "google_pubsub_topic_iam_member" "pubsub_dlq_publisher" {
  topic  = google_pubsub_topic.job_requests_dlq.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription_iam_member" "pubsub_dlq_subscriber" {
  subscription = google_pubsub_subscription.job_requests_sub.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

output "job_requests_topic" {
  value = google_pubsub_topic.job_requests.name
}

output "job_requests_topic_id" {
  value = google_pubsub_topic.job_requests.id
}
