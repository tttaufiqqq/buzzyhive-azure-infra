output "resource_group_name" {
  value = azurerm_resource_group.iac.name
}

output "storage_account_name" {
  value = azurerm_storage_account.state.name
}

output "container_name" {
  value = azurerm_storage_container.tfstate.name
}

output "backend_hcl" {
  description = "Paste into foundation/backend.hcl and lab/backend.hcl (change the key per root)."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.iac.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    use_azuread_auth     = true
  EOT
}
