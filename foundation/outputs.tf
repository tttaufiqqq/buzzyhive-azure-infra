output "resource_group_name" {
  value = azurerm_resource_group.lab.name
}

output "managed_identity_name" {
  value = azurerm_user_assigned_identity.apps.name
}

output "pipeline_client_id" {
  description = "Save as the GitHub repository variable AZURE_CLIENT_ID."
  value       = azuread_application.pipeline.client_id
}

output "tenant_id" {
  description = "Save as the GitHub repository variable AZURE_TENANT_ID."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Save as the GitHub repository variable AZURE_SUBSCRIPTION_ID."
  value       = data.azurerm_subscription.current.subscription_id
}
