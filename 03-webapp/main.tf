terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_resource_group" "resume" {
  name = var.resource_group_name
}

data "azurerm_storage_account" "web" {
  name                = var.web_storage_name
  resource_group_name = var.resource_group_name
}
