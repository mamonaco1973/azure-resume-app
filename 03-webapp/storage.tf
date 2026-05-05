# ================================================================================
# 03-webapp/storage.tf
# Upload the SPA to the $web container of the web storage account.
# apply.sh generates config.js and config.json before this runs,
# so fileset picks them up automatically alongside the static assets.
# ================================================================================

locals {
  site_dir = "${path.module}/site"

  mime_types = {
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
    ".json" = "application/json"
    ".ico"  = "image/x-icon"
    ".png"  = "image/png"
    ".svg"  = "image/svg+xml"
  }
}

resource "azurerm_storage_blob" "site_files" {
  for_each = fileset(local.site_dir, "**")

  name                   = each.value
  storage_account_name   = data.azurerm_storage_account.web.name
  storage_container_name = "$web"
  type                   = "Block"
  source                 = "${local.site_dir}/${each.value}"

  content_type = lookup(
    local.mime_types,
    regex("\\.[^.]+$", each.value),
    "application/octet-stream"
  )

  # Generated config files must not be cached — re-deploy changes config values
  cache_control = (
    each.value == "config.json" || each.value == "js/config.js"
    ? "no-cache, no-store, must-revalidate"
    : null
  )
}
