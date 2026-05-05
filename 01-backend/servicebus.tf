# ================================================================================
# Service Bus Namespace + Queue
# Replaces GCP Pub/Sub. RBAC-only auth (local_auth_enabled=false).
# Role assignments are made in 02-functions once the Function App identity exists.
# ================================================================================

resource "azurerm_servicebus_namespace" "resume" {
  name                = "sb-resume-${random_id.suffix.hex}"
  location            = azurerm_resource_group.resume.location
  resource_group_name = azurerm_resource_group.resume.name
  sku                 = "Standard"
  local_auth_enabled  = false
}

resource "azurerm_servicebus_queue" "scoring_jobs" {
  name         = "resume-scoring-jobs"
  namespace_id = azurerm_servicebus_namespace.resume.id

  # lock_duration exceeds the worker timeout so a message cannot be
  # re-delivered while scoring is still in progress
  lock_duration      = "PT5M"
  max_delivery_count = 5

  # TTL matches the job 90-day retention window
  default_message_ttl                  = "P90D"
  dead_lettering_on_message_expiration = true

  max_size_in_megabytes        = 1024
  requires_duplicate_detection = false
  requires_session             = false
}
