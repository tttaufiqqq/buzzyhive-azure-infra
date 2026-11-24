# Subscription-scope guard rails. Policy is in audit mode (enforce = false) so it
# reports problems but never blocks an apply, including resources Azure creates
# itself such as the Container Apps managed resource group.

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations-${var.project}"
  display_name         = "Allowed locations (${var.project})"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
  enforce              = false

  parameters = jsonencode({
    listOfAllowedLocations = { value = var.allowed_locations }
  })
}

resource "azurerm_subscription_policy_assignment" "require_tag" {
  for_each = toset(["env", "project"])

  name                 = "require-tag-${each.key}"
  display_name         = "Require tag ${each.key} on resource groups"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025"
  enforce              = false

  parameters = jsonencode({
    tagName = { value = each.key }
  })
}

# A budget only notifies. It does not stop spending.
resource "azurerm_consumption_budget_subscription" "lab" {
  count           = var.enable_budget ? 1 : 0
  name            = "budget-${var.project}-${var.env}"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = var.budget_start_date # first day of a month, e.g. 2026-11-01T00:00:00Z
  }

  dynamic "notification" {
    for_each = var.budget_thresholds

    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThanOrEqualTo"
      threshold_type = "Actual"
      contact_emails = var.alert_emails
    }
  }
}

# Defender for Cloud stays on its free tier: no resource is created here.
