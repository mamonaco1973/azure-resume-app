variable "location" {
  description = "Azure region — must match 01-backend"
  type        = string
  default     = "Central US"
}

variable "resource_group_name" {
  description = "Resource group created by 01-backend"
  type        = string
  default     = "resume-app-rg"
}

variable "servicebus_namespace_fqdn" {
  type = string
}

variable "servicebus_queue_name" {
  type = string
}

variable "servicebus_queue_id" {
  type = string
}

variable "cosmos_endpoint" {
  type = string
}

variable "cosmos_account_name" {
  type = string
}

variable "cosmos_role_definition_id" {
  type = string
}

variable "media_storage_id" {
  description = "Resource ID of the media storage account (for RBAC scope)"
  type        = string
}

variable "media_blob_endpoint" {
  type = string
}

variable "aoai_endpoint" {
  description = "Azure OpenAI account endpoint"
  type        = string
}

variable "aoai_account_id" {
  description = "Azure OpenAI account resource ID (for RBAC scope)"
  type        = string
}

variable "aoai_model_deployment" {
  description = "Azure OpenAI model deployment name"
  type        = string
}

variable "entra_tenant_name" {
  type = string
}

variable "entra_tenant_id" {
  type = string
}

variable "entra_client_id" {
  type = string
}

variable "web_origin" {
  description = "Web storage primary_web_endpoint (for CORS)"
  type        = string
}
