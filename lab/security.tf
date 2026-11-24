# ---------- Key Vault (private) ----------

resource "azurerm_key_vault" "this" {
  name                = local.names.kv
  resource_group_name = local.rg
  location            = local.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled    = true
  public_network_access_enabled = false
  purge_protection_enabled      = false # lab: lets terraform destroy purge it
  soft_delete_retention_days    = 7

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pep-${local.names.kv}"
  resource_group_name = local.rg
  location            = local.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.names.kv}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "vault"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["vault"].id]
  }
}

# With public access off, a laptop or runner outside the VNet gets 403 on the
# Key Vault data plane. Writing secrets through ARM (azapi) avoids the data plane.
locals {
  secret_values = merge(
    { "db-password" = random_password.mysql.result },
    var.app_secrets,
  )
  secret_names = toset(concat(["db-password"], nonsensitive(keys(var.app_secrets))))
}

resource "azapi_resource" "secret" {
  for_each = local.secret_names

  type      = "Microsoft.KeyVault/vaults/secrets@2023-07-01"
  name      = each.key
  parent_id = azurerm_key_vault.this.id

  sensitive_body = {
    properties = {
      value = local.secret_values[each.key]
    }
  }
}

# ---------- Storage: private account for Laravel files ----------
# Created with azapi so Terraform never calls the storage data plane, which
# would return 403 from outside the VNet once public access is disabled.

resource "azapi_resource" "storage_private" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = local.names.st_private
  parent_id = data.azurerm_resource_group.lab.id
  location  = local.location
  tags      = local.tags

  body = {
    kind = "StorageV2"
    sku  = { name = "Standard_LRS" }
    properties = {
      publicNetworkAccess      = "Disabled"
      allowBlobPublicAccess    = false
      minimumTlsVersion        = "TLS1_2"
      supportsHttpsTrafficOnly = true
      networkAcls = {
        defaultAction = "Deny"
        bypass        = "None"
      }
    }
  }
}

resource "azurerm_private_endpoint" "storage_blob" {
  name                = "pep-${local.names.st_private}-blob"
  resource_group_name = local.rg
  location            = local.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.names.st_private}-blob"
    private_connection_resource_id = azapi_resource.storage_private.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["blob"].id]
  }
}

# ---------- Storage: public account for the Function and the ML workspace ----------
# A Functions Consumption plan generally cannot use storage behind a private
# endpoint, so this account has none. VERIFY against current Functions docs.

resource "azurerm_storage_account" "public" {
  name                     = local.names.st_public
  resource_group_name      = local.rg
  location                 = local.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false

  tags = local.tags
}

# ---------- Container Registry ----------

resource "azurerm_container_registry" "this" {
  name                = local.names.acr
  resource_group_name = local.rg
  location            = local.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

# ---------- Roles for the apps' managed identity ----------

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = data.azurerm_user_assigned_identity.apps.principal_id
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_user_assigned_identity.apps.principal_id
}
