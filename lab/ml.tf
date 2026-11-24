# Azure Machine Learning: training only. flask-ml in Container Apps keeps serving
# the model, so no managed online endpoint (which would bill all the time).
# Off by default; set enable_ml = true for the ML session.

# The workspace gets its own Key Vault. The main one has public access disabled,
# which a workspace cannot use. VERIFY the access model against current docs.
resource "azurerm_key_vault" "ml" {
  count                      = var.enable_ml ? 1 : 0
  name                       = local.names.kv_ml
  resource_group_name        = local.rg
  location                   = local.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = local.tags
}

resource "azurerm_machine_learning_workspace" "this" {
  count                         = var.enable_ml ? 1 : 0
  name                          = local.names.mlw
  resource_group_name           = local.rg
  location                      = local.location
  application_insights_id       = azurerm_application_insights.this.id
  key_vault_id                  = azurerm_key_vault.ml[0].id
  storage_account_id            = azurerm_storage_account.public.id
  public_network_access_enabled = true
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }

  # Azure ML creates its own Container Registry on the first job and attaches it to the
  # workspace. The registry is not in Terraform state, and removing the attribute forces the
  # workspace (and so the compute cluster) to be replaced. Ignore it, and delete the registry
  # by hand at teardown (scripts/down.ps1 lists it). See troubleshooting entry 37.
  lifecycle {
    ignore_changes = [container_registry_id]
  }
}

resource "azurerm_machine_learning_compute_cluster" "train" {
  count                         = var.enable_ml ? 1 : 0
  name                          = "train-cpu"
  location                      = local.location
  vm_priority                   = "Dedicated"
  vm_size                       = var.ml_vm_size
  machine_learning_workspace_id = azurerm_machine_learning_workspace.this[0].id

  # Scales to zero when idle, so it only bills while a job runs.
  scale_settings {
    min_node_count                       = 0
    max_node_count                       = 1
    scale_down_nodes_after_idle_duration = "PT15M"
  }

  identity {
    type = "SystemAssigned"
  }
}
