variable "resource_group_name" {
  description = "Resource group created by 01-backend"
  type        = string
  default     = "resume-app-rg"
}

variable "web_storage_name" {
  description = "Web storage account name from 01-backend output"
  type        = string
}
