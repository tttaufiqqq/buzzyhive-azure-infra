resource "random_password" "mysql" {
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
}

resource "azurerm_mysql_flexible_server" "this" {
  name                   = local.names.mysql
  resource_group_name    = local.rg
  location               = local.location
  administrator_login    = var.mysql_admin_login
  administrator_password = random_password.mysql.result
  sku_name               = "B_Standard_B1ms"
  version                = "8.0.21"
  backup_retention_days  = 7

  # Private access: a delegated subnet plus a linked private DNS zone.
  delegated_subnet_id = azurerm_subnet.mysql.id
  private_dns_zone_id = azurerm_private_dns_zone.this["mysql"].id

  storage {
    size_gb = 20
  }

  tags = local.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]

  lifecycle {
    ignore_changes = [zone]
  }
}

# The app's migrations create a trigger (HRI_Summary). Azure keeps binary logging
# on and the admin user has no SUPER privilege, so without this the migrate Job
# fails with error 1419.
resource "azurerm_mysql_flexible_server_configuration" "trust_function_creators" {
  name                = "log_bin_trust_function_creators"
  resource_group_name = local.rg
  server_name         = azurerm_mysql_flexible_server.this.name
  value               = "ON"
}

resource "azurerm_mysql_flexible_database" "app" {
  name                = var.mysql_database
  resource_group_name = local.rg
  server_name         = azurerm_mysql_flexible_server.this.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# Alerts: database CPU, mirroring the "DB CPU" rule on the diagram.
resource "azurerm_monitor_action_group" "this" {
  name                = local.names.ag
  resource_group_name = local.rg
  short_name          = "hivealert"

  email_receiver {
    name          = "owner"
    email_address = var.alert_email
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "mysql_cpu" {
  name                = "alert-${local.base}-mysql-cpu"
  resource_group_name = local.rg
  scopes              = [azurerm_mysql_flexible_server.this.id]
  description         = "MySQL CPU above 80% for 15 minutes"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforMySQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = local.tags
}
