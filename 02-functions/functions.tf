# ================================================================================
# Azure Functions (Flex Consumption) — resume API + Service Bus worker
# All HTTP routes and the Service Bus queue trigger live in one app.
# ================================================================================

resource "azurerm_storage_account" "functions" {
  name                     = "resumefunc${random_id.suffix.hex}"
  resource_group_name      = data.azurerm_resource_group.resume.name
  location                 = data.azurerm_resource_group.resume.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "func_code" {
  name                  = "func-code"
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

resource "azurerm_service_plan" "resume" {
  name                = "resume-plan-${random_id.suffix.hex}"
  resource_group_name = data.azurerm_resource_group.resume.name
  location            = data.azurerm_resource_group.resume.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_application_insights" "resume" {
  name                = "resume-ai-${random_id.suffix.hex}"
  resource_group_name = data.azurerm_resource_group.resume.name
  location            = data.azurerm_resource_group.resume.location
  application_type    = "web"
}

resource "azurerm_function_app_flex_consumption" "resume" {
  name                = "resume-func-${random_id.suffix.hex}"
  resource_group_name = data.azurerm_resource_group.resume.name
  location            = data.azurerm_resource_group.resume.location

  service_plan_id = azurerm_service_plan.resume.id
  https_only      = true

  identity {
    type = "SystemAssigned"
  }

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.func_code.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.functions.primary_access_key

  runtime_name    = "python"
  runtime_version = "3.11"

  maximum_instance_count = 10
  instance_memory_in_mb  = 2048

  site_config {
    cors {
      # Lock CORS to the exact web storage origin so Authorization headers
      # are accepted in cross-origin requests
      allowed_origins     = [trimsuffix(var.web_origin, "/")]
      support_credentials = false
    }
  }

  app_settings = {
    FUNCTIONS_EXTENSION_VERSION           = "~4"
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.resume.connection_string
    AzureWebJobsFeatureFlags              = "EnableWorkerIndexing"

    # Service Bus — RBAC auth via managed identity
    SERVICEBUS_NAMESPACE_FQDN                     = var.servicebus_namespace_fqdn
    SERVICEBUS_QUEUE_NAME                         = var.servicebus_queue_name
    ServiceBusConnection__fullyQualifiedNamespace = var.servicebus_namespace_fqdn

    # Cosmos DB — RBAC auth via managed identity
    COSMOS_ENDPOINT              = var.cosmos_endpoint
    COSMOS_DATABASE_NAME         = "resume-app"
    COSMOS_RESUMES_CONTAINER     = "resumes"
    COSMOS_JOBS_CONTAINER        = "jobs"
    COSMOS_FOLDERS_CONTAINER     = "folders"
    COSMOS_USERS_CONTAINER       = "users"

    # Media blob storage — managed identity access via Storage Blob Data Contributor
    MEDIA_BLOB_ENDPOINT = var.media_blob_endpoint

    # Azure OpenAI — managed identity access via Cognitive Services OpenAI User
    AOAI_ENDPOINT         = var.aoai_endpoint
    AOAI_MODEL_DEPLOYMENT = var.aoai_model_deployment

    # Entra External ID — JWT validation
    ENTRA_TENANT_NAME = var.entra_tenant_name
    ENTRA_TENANT_ID   = var.entra_tenant_id
    ENTRA_CLIENT_ID   = var.entra_client_id
  }

  lifecycle {
    ignore_changes = [
      app_settings["APPLICATIONINSIGHTS_CONNECTION_STRING"],
      app_settings["FUNCTIONS_EXTENSION_VERSION"],
      app_settings["SCM_DO_BUILD_DURING_DEPLOYMENT"],
      # Provider bug: cors block count flips 0→1 between plan and apply
      site_config,
    ]
  }
}

# ================================================================================
# RBAC — Service Bus
# ================================================================================

resource "azurerm_role_assignment" "sb_sender" {
  scope                = var.servicebus_queue_id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_function_app_flex_consumption.resume.identity[0].principal_id
}

resource "azurerm_role_assignment" "sb_receiver" {
  scope                = var.servicebus_queue_id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_function_app_flex_consumption.resume.identity[0].principal_id
}

# ================================================================================
# RBAC — Cosmos DB
# ================================================================================

resource "azurerm_cosmosdb_sql_role_assignment" "func_cosmos" {
  name = uuidv5(
    "dns",
    "${var.cosmos_account_name}:${azurerm_function_app_flex_consumption.resume.identity[0].principal_id}"
  )

  resource_group_name = data.azurerm_resource_group.resume.name
  account_name        = var.cosmos_account_name

  principal_id       = azurerm_function_app_flex_consumption.resume.identity[0].principal_id
  role_definition_id = var.cosmos_role_definition_id
  scope              = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.azurerm_resource_group.resume.name}/providers/Microsoft.DocumentDB/databaseAccounts/${var.cosmos_account_name}"
}

# ================================================================================
# RBAC — Blob Storage (media account)
# Server-side read/write of resume text and job artifacts.
# ================================================================================

resource "azurerm_role_assignment" "blob_contributor" {
  scope                = var.media_storage_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.resume.identity[0].principal_id
}

# ================================================================================
# RBAC — Azure OpenAI
# ================================================================================

resource "azurerm_role_assignment" "aoai_user" {
  scope                = var.aoai_account_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_function_app_flex_consumption.resume.identity[0].principal_id
}

data "azurerm_client_config" "current" {}
