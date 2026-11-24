resource "azurerm_log_analytics_workspace" "this" {
  name                = local.names.log
  resource_group_name = local.rg
  location            = local.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = local.names.appi
  resource_group_name = local.rg
  location            = local.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = local.tags
}
