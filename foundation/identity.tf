# Entra groups, the managed identity the apps use, and the GitHub OIDC identity
# the pipeline signs in with. Needs directory rights in your tenant.

resource "azuread_group" "admins" {
  display_name     = "grp-${var.project}-admins"
  security_enabled = true
}

resource "azuread_group" "readers" {
  display_name     = "grp-${var.project}-readers"
  security_enabled = true
}

# Created here so it survives "terraform destroy" in lab/. The lab root grants
# it AcrPull and Key Vault Secrets User once those resources exist.
resource "azurerm_user_assigned_identity" "apps" {
  name                = "id-${var.project}-${var.env}-apps"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = local.tags
}

resource "azuread_application" "pipeline" {
  display_name = "sp-${var.project}-${var.env}-pipeline"
}

resource "azuread_service_principal" "pipeline" {
  client_id = azuread_application.pipeline.client_id
}

# No client secret: GitHub Actions exchanges its OIDC token for an Azure token.
resource "azuread_application_federated_identity_credential" "github_env" {
  application_id = azuread_application.pipeline.id
  display_name   = "github-${var.github_environment}"
  description    = "GitHub Actions, environment ${var.github_environment}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_owner}/${var.github_repo}:environment:${var.github_environment}"
}

resource "azuread_application_federated_identity_credential" "github_pr" {
  application_id = azuread_application.pipeline.id
  display_name   = "github-pull-request"
  description    = "GitHub Actions, pull requests (plan only)"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_owner}/${var.github_repo}:pull_request"
}

# ---------- RBAC on the resource group ----------

resource "azurerm_role_assignment" "pipeline_contributor" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.pipeline.object_id

  # A new service principal may not have replicated yet; skip the lookup.
  skip_service_principal_aad_check = true
}

# Contributor cannot create role assignments, which lab/ needs to do.
resource "azurerm_role_assignment" "pipeline_rbac_admin" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.pipeline.object_id

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "readers" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Reader"
  principal_id         = azuread_group.readers.object_id
}

resource "azurerm_role_assignment" "admins" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Contributor"
  principal_id         = azuread_group.admins.object_id
}

# The pipeline also needs to read and write the Terraform state.
data "azurerm_storage_account" "state" {
  count               = var.state_storage_account_name == null ? 0 : 1
  name                = var.state_storage_account_name
  resource_group_name = var.state_resource_group_name
}

resource "azurerm_role_assignment" "pipeline_state" {
  count                = var.state_storage_account_name == null ? 0 : 1
  scope                = data.azurerm_storage_account.state[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.pipeline.object_id

  skip_service_principal_aad_check = true
}
