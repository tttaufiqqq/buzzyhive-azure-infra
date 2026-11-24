terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  # Partial configuration. Run: terraform init -backend-config=backend.hcl
  # (copy backend.hcl.example and use the bootstrap output).
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  use_oidc        = var.use_oidc
}

provider "azuread" {
  use_oidc = var.use_oidc
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

locals {
  tags = {
    project    = var.project
    env        = var.env
    managed_by = "terraform"
  }
}

# The resource group lives here, not in lab/, so "terraform destroy" in lab/
# removes the workloads but keeps the group, its RBAC and its identity.
resource "azurerm_resource_group" "lab" {
  name     = "rg-${var.project}-${var.env}"
  location = var.location
  tags     = local.tags
}

# Optional guard rail. Off in the lab, because a CanNotDelete lock on the group
# makes "terraform destroy" in lab/ fail.
resource "azurerm_management_lock" "rg" {
  count      = var.enable_locks ? 1 : 0
  name       = "lock-${azurerm_resource_group.lab.name}"
  scope      = azurerm_resource_group.lab.id
  lock_level = "CanNotDelete"
  notes      = "Protects MySQL and Key Vault. Set enable_locks = false before destroying lab/."
}
