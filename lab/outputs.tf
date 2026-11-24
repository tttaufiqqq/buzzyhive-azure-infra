output "web_url" {
  value = "https://${azurerm_container_app.web.ingress[0].fqdn}"
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "mysql_fqdn" {
  value = azurerm_mysql_flexible_server.this.fqdn
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "iothub_name" {
  value = one(azurerm_iothub.this[*].name)
}

output "function_name" {
  value = one(concat(azurerm_linux_function_app.forwarder[*].name, azurerm_function_app_flex_consumption.forwarder[*].name))
}

output "ml_workspace_name" {
  value = one(azurerm_machine_learning_workspace.this[*].name)
}
