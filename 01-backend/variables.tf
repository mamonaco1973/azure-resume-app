variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "Central US"
}

variable "entra_tenant_id" {
  description = "Entra External tenant ID"
  type        = string
}

variable "entra_tenant_name" {
  description = "Entra External tenant name (e.g. mytenantname)"
  type        = string
}

variable "entra_sp_client_id" {
  description = "Service principal client ID with Graph permissions in the External tenant"
  type        = string
}

variable "entra_sp_client_secret" {
  description = "Service principal client secret"
  type        = string
  sensitive   = true
}

variable "aoai_model_deployment" {
  description = "Azure OpenAI model deployment name (e.g. gpt-4o)"
  type        = string
  default     = "gpt-4o"
}
