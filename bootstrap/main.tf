terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state on purpose: this root creates the storage account that
  # foundation/ and lab/ use for remote state.
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id # null = use ARM_SUBSCRIPTION_ID
}

locals {
  tags = {
    project    = var.project
    env        = var.env
    managed_by = "terraform"
  }
}

resource "random_string" "state" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "iac" {
  name     = "rg-${var.project}-iac"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "state" {
  name                     = "st${var.project}tf${random_string.state.result}"
  resource_group_name      = azurerm_resource_group.iac.name
  location                 = azurerm_resource_group.iac.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}
