output "function_app_name" {
  value = azurerm_function_app_flex_consumption.resume.name
}

output "function_app_url" {
  value = "https://${azurerm_function_app_flex_consumption.resume.default_hostname}/api"
}
