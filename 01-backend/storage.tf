# ================================================================================
# Storage Accounts
# web   — static website hosting for the SPA ($web container)
# media — private blob storage for resume and job artifacts
#
# Web storage lives in 01-backend so its URL is known before the Entra app
# registration redirect URI is written.
# ================================================================================

# ------------------------------------------------------------------------------
# Web storage (SPA hosting)
# ------------------------------------------------------------------------------
resource "azurerm_storage_account" "web" {
  name                     = "resumeweb${random_id.suffix.hex}"
  resource_group_name      = azurerm_resource_group.resume.name
  location                 = azurerm_resource_group.resume.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_account_static_website" "web" {
  storage_account_id = azurerm_storage_account.web.id
  index_document     = "index.html"
}

# ------------------------------------------------------------------------------
# Media storage (resume text + job artifacts, private)
# All access is server-side via managed identity — no SAS tokens needed.
# ------------------------------------------------------------------------------
resource "azurerm_storage_account" "media" {
  name                     = "resumemedia${random_id.suffix.hex}"
  resource_group_name      = azurerm_resource_group.resume.name
  location                 = azurerm_resource_group.resume.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "resumes" {
  name                  = "resumes"
  storage_account_id    = azurerm_storage_account.media.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "jobs" {
  name                  = "jobs"
  storage_account_id    = azurerm_storage_account.media.id
  container_access_type = "private"
}
