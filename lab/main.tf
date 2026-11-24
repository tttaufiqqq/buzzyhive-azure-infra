terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial configuration. Run: terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id
  use_oidc        = var.use_oidc

  features {
    # The lab is destroyed and recreated often. Without these, soft-deleted
    # names stay reserved and the next apply fails.
    key_vault {
      purge_soft_delete_on_destroy = true
    }
    machine_learning {
      purge_soft_deleted_workspace_on_destroy = true
    }
  }
}

provider "azapi" {
  use_oidc = var.use_oidc
}

data "azurerm_client_config" "current" {}

# Created by the foundation root, so they survive "terraform destroy" here.
data "azurerm_resource_group" "lab" {
  name = "rg-${var.project}-${var.env}"
}

data "azurerm_user_assigned_identity" "apps" {
  name                = "id-${var.project}-${var.env}-apps"
  resource_group_name = data.azurerm_resource_group.lab.name
}

# Short random suffix for globally unique names (ACR, Key Vault, storage,
# Function, MySQL).
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  rg       = data.azurerm_resource_group.lab.name
  location = data.azurerm_resource_group.lab.location
  sfx      = random_string.suffix.result
  base     = "${var.project}-${var.env}"

  tags = {
    project    = var.project
    env        = var.env
    managed_by = "terraform"
  }

  # ---------- IP plan ----------
  vnet_cidr     = "10.0.0.0/16"
  snet_aca_cidr = "10.0.0.0/23"
  snet_pe_cidr  = "10.0.2.0/24"
  snet_sql_cidr = "10.0.4.0/28"

  # ---------- Names (Cloud Adoption Framework abbreviations) ----------
  names = {
    vnet       = "vnet-${local.base}"
    snet_aca   = "snet-aca"
    snet_pe    = "snet-pe"
    snet_mysql = "snet-mysql"
    nsg_aca    = "nsg-snet-aca"
    nsg_pe     = "nsg-snet-pe"
    nsg_mysql  = "nsg-snet-mysql"
    mysql      = "mysql-${local.base}-${local.sfx}"
    kv         = "kv-${var.project}-${local.sfx}"
    kv_ml      = "kvml-${var.project}-${local.sfx}"
    st_private = "st${var.project}app${local.sfx}"
    st_public  = "st${var.project}fn${local.sfx}"
    acr        = "acr${var.project}${local.sfx}"
    log        = "log-${local.base}"
    appi       = "appi-${local.base}"
    acae       = "acae-${local.base}"
    iothub     = "iot-${local.base}-${local.sfx}"
    func       = "func-${local.base}-${local.sfx}"
    plan       = "asp-${local.base}"
    mlw        = "mlw-${local.base}"
    ag         = "ag-${local.base}"
  }

  placeholder_image = "mcr.microsoft.com/k8se/quickstart:latest"
  use_placeholders  = var.images.laravel == null || var.images.flask == null
}
