output "website_url" {
  value = data.azurerm_storage_account.web.primary_web_endpoint
}
