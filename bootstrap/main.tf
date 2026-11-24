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
    project    = var.project_tag
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

data "azurerm_client_config" "current" {}

# The backend in foundation/ and lab/ uses Azure AD auth (use_azuread_auth). Owner
# or Contributor is not enough for that: reading and writing blobs needs this
# data-plane role. Role assignments can take a few minutes to take effect.
resource "azurerm_role_assignment" "state_deployer" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}
