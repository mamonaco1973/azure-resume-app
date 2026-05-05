# ================================================================================
# Azure OpenAI — GPT-4o for the 2-phase resume scoring pipeline
# Replaces GCP Vertex AI Gemini. The Function App accesses it via
# managed identity (Cognitive Services OpenAI User role in 02-functions).
# ================================================================================

resource "azurerm_cognitive_account" "openai" {
  name                  = "resume-aoai-${random_id.suffix.hex}"
  location              = azurerm_resource_group.resume.location
  resource_group_name   = azurerm_resource_group.resume.name
  kind                  = "OpenAI"
  sku_name              = "S0"

  # custom_subdomain_name is required for RBAC-based auth (no key in code)
  custom_subdomain_name = "resume-aoai-${random_id.suffix.hex}"
}

resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = var.aoai_model_deployment
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4o"
    version = "2024-11-20"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 100 # 100K TPM
  }
}
