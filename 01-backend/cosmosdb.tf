# ================================================================================
# Cosmos DB — resume and job state store
# Two containers: resumes (no default expiry) and jobs (90-day TTL).
# Partition key /owner maps to the JWT sub claim for per-user isolation.
# ================================================================================

resource "azurerm_cosmosdb_account" "resume" {
  name                = "cosmos-resume-${random_id.suffix.hex}"
  location            = azurerm_resource_group.resume.location
  resource_group_name = azurerm_resource_group.resume.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.resume.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "resume" {
  name                = "resume-app"
  resource_group_name = azurerm_resource_group.resume.name
  account_name        = azurerm_cosmosdb_account.resume.name
}

# ------------------------------------------------------------------------------
# Resumes container — no TTL; users keep resumes indefinitely
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_sql_container" "resumes" {
  name                = "resumes"
  resource_group_name = azurerm_resource_group.resume.name
  account_name        = azurerm_cosmosdb_account.resume.name
  database_name       = azurerm_cosmosdb_sql_database.resume.name
  partition_key_paths = ["/owner"]

  # -1 enables TTL without a default; items without a ttl field never expire
  default_ttl = -1

  throughput = 400

  indexing_policy {
    indexing_mode = "consistent"
    included_path { path = "/*" }
    excluded_path { path = "/\"_etag\"/?" }
  }

  lifecycle {
    ignore_changes = [indexing_policy]
  }
}

# ------------------------------------------------------------------------------
# Jobs container — no TTL; jobs are retained indefinitely
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_sql_container" "jobs" {
  name                = "jobs"
  resource_group_name = azurerm_resource_group.resume.name
  account_name        = azurerm_cosmosdb_account.resume.name
  database_name       = azurerm_cosmosdb_sql_database.resume.name
  partition_key_paths = ["/owner"]

  default_ttl = -1

  throughput = 400

  indexing_policy {
    indexing_mode = "consistent"
    included_path { path = "/*" }
    excluded_path { path = "/\"_etag\"/?" }
  }

  lifecycle {
    ignore_changes = [indexing_policy]
  }
}

# ------------------------------------------------------------------------------
# Folders container — no TTL; user-defined job folders
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_sql_container" "folders" {
  name                = "folders"
  resource_group_name = azurerm_resource_group.resume.name
  account_name        = azurerm_cosmosdb_account.resume.name
  database_name       = azurerm_cosmosdb_sql_database.resume.name
  partition_key_paths = ["/owner"]

  default_ttl = -1

  throughput = 400

  indexing_policy {
    indexing_mode = "consistent"
    included_path { path = "/*" }
    excluded_path { path = "/\"_etag\"/?" }
  }

  lifecycle {
    ignore_changes = [indexing_policy]
  }
}

# ------------------------------------------------------------------------------
# Users container — token usage per user; no TTL
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_sql_container" "users" {
  name                = "users"
  resource_group_name = azurerm_resource_group.resume.name
  account_name        = azurerm_cosmosdb_account.resume.name
  database_name       = azurerm_cosmosdb_sql_database.resume.name
  partition_key_paths = ["/owner"]

  default_ttl = -1

  throughput = 400

  indexing_policy {
    indexing_mode = "consistent"
    included_path { path = "/*" }
    excluded_path { path = "/\"_etag\"/?" }
  }

  lifecycle {
    ignore_changes = [indexing_policy]
  }
}

# ================================================================================
# Cosmos DB RBAC — custom role for the Function App managed identity
# Scoped to the account so both containers are accessible.
# ================================================================================

resource "azurerm_cosmosdb_sql_role_definition" "func_role" {
  name                = "ResumeAppFuncRole"
  resource_group_name = azurerm_resource_group.resume.name
  account_name        = azurerm_cosmosdb_account.resume.name
  type                = "CustomRole"
  assignable_scopes   = [azurerm_cosmosdb_account.resume.id]

  permissions {
    data_actions = [
      "Microsoft.DocumentDB/databaseAccounts/readMetadata",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*",
    ]
  }
}
