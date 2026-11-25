# IoT Hub (free tier) and the Function that forwards each message to Laravel.
# IoT Hub and the Function sit outside the VNet; the Function calls the public
# laravel-web ingress with the API key.
#
# This file creates the Function app. The function itself is the code in functions/forwarder/,
# which scripts/deploy-function.ps1 uploads after the apply (enable_function = true).
#
# Two ways to host it, chosen with function_hosting:
#   "flex" (default) Flex Consumption (FC1) and azurerm_function_app_flex_consumption. It has its
#                    own regional memory quota. It worked on the Free Trial subscription on
#                    25/11/2026, in East US (function_location = "eastus").
#   "plan"           a classic App Service plan (B1, Y1, ...) and azurerm_linux_function_app. On the
#                    Free Trial subscription this failed: Y1 was refused in Malaysia West, and the
#                    quota for B1 and Y1 instances was 0 in Southeast Asia and East US.

locals {
  function_enabled = var.enable_iot && var.enable_function
  function_plan    = local.function_enabled && var.function_hosting == "plan"
  function_flex    = local.function_enabled && var.function_hosting == "flex"
}

resource "azurerm_iothub" "this" {
  count               = var.enable_iot ? 1 : 0
  name                = local.names.iothub
  resource_group_name = local.rg
  location            = var.iothub_location # not offered in the resource group's region
  tags                = local.tags

  event_hub_partition_count = 2 # the F1 tier allows exactly 2; the provider default is 4

  sku {
    name     = "F1" # free tier: 8,000 messages per day, one per subscription
    capacity = 1
  }
}

resource "azurerm_iothub_shared_access_policy" "function" {
  count               = local.function_enabled ? 1 : 0
  name                = "function"
  resource_group_name = local.rg
  iothub_name         = azurerm_iothub.this[0].name
  service_connect     = true
}

# ---------- hosting "plan": a classic App Service plan ----------

resource "azurerm_service_plan" "function" {
  count               = local.function_plan ? 1 : 0
  name                = local.names.plan
  resource_group_name = local.rg
  location            = coalesce(var.function_location, local.location)
  os_type             = "Linux"
  sku_name            = var.function_plan_sku # B1 by default
  tags                = local.tags
}

resource "azurerm_linux_function_app" "forwarder" {
  count                      = local.function_plan ? 1 : 0
  name                       = local.names.func
  resource_group_name        = local.rg
  location                   = coalesce(var.function_location, local.location)
  service_plan_id            = azurerm_service_plan.function[0].id
  storage_account_name       = azurerm_storage_account.public.name
  storage_account_access_key = azurerm_storage_account.public.primary_access_key
  tags                       = local.tags

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
    # A dedicated plan needs Always On or the Event Hub trigger stops when the app idles. Y1 cannot use it.
    always_on = var.function_plan_sku != "Y1"

    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    # Event Hub-compatible endpoint of the IoT Hub, read by the IoT Hub trigger.
    IOTHUB_EVENTS_CONNECTION = "Endpoint=${azurerm_iothub.this[0].event_hub_events_endpoint};SharedAccessKeyName=${azurerm_iothub_shared_access_policy.function[0].name};SharedAccessKey=${azurerm_iothub_shared_access_policy.function[0].primary_key};EntityPath=${azurerm_iothub.this[0].event_hub_events_path}"
    # The trigger reads the event hub name from here (event_hub_name = "%IOTHUB_EVENTS_PATH%").
    IOTHUB_EVENTS_PATH = azurerm_iothub.this[0].event_hub_events_path
    LARAVEL_URL        = "https://${azurerm_container_app.web.ingress[0].fqdn}"
    # A plain app setting, not a Key Vault reference: the vault has public access off and the
    # Function sits outside the VNet, so it could not resolve one. Anyone who can read the app's
    # settings can read this key.
    LARAVEL_API_KEY = var.function_api_key

    # scripts/deploy-function.ps1 uploads a zip and Azure installs requirements.txt on the server.
    # Declared here so a later plan does not try to remove the settings the deployment adds.
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    ENABLE_ORYX_BUILD              = "true"
  }

  lifecycle {
    # Azure adds this tag when the app is linked to Application Insights.
    ignore_changes = [tags["hidden-link: /app-insights-resource-id"]]

    precondition {
      condition     = var.function_api_key != null
      error_message = "Set function_api_key when enable_function is true."
    }
  }
}

# ---------- hosting "flex": Flex Consumption ----------

resource "azurerm_service_plan" "function_flex" {
  count               = local.function_flex ? 1 : 0
  name                = "${local.names.plan}-flex"
  resource_group_name = local.rg
  location            = coalesce(var.function_location, local.location)
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

# Flex Consumption runs the code from a blob container instead of a file share.
resource "azurerm_storage_container" "function_deploy" {
  count                 = local.function_flex ? 1 : 0
  name                  = "function-deploy"
  storage_account_id    = azurerm_storage_account.public.id
  container_access_type = "private"
}

resource "azurerm_function_app_flex_consumption" "forwarder" {
  count               = local.function_flex ? 1 : 0
  name                = local.names.func
  resource_group_name = local.rg
  # Same region as the storage account (function_location = null) is best for latency, but
  # Microsoft calls it a performance optimization, not a rule, when the app is created outside
  # the portal. A different region works in principle and was not tried here.
  location        = coalesce(var.function_location, local.location)
  service_plan_id = azurerm_service_plan.function_flex[0].id
  tags            = local.tags

  runtime_name    = "python"
  runtime_version = "3.11"

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${trimsuffix(azurerm_storage_account.public.primary_blob_endpoint, "/")}/${azurerm_storage_container.function_deploy[0].name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.public.primary_access_key

  # The smallest instance size, to use as little of the regional memory quota as possible.
  instance_memory_in_mb  = 512
  maximum_instance_count = 10

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
  }

  app_settings = {
    # The Event Hubs trigger keeps its checkpoints in this storage account.
    AzureWebJobsStorage = azurerm_storage_account.public.primary_connection_string

    IOTHUB_EVENTS_CONNECTION = "Endpoint=${azurerm_iothub.this[0].event_hub_events_endpoint};SharedAccessKeyName=${azurerm_iothub_shared_access_policy.function[0].name};SharedAccessKey=${azurerm_iothub_shared_access_policy.function[0].primary_key};EntityPath=${azurerm_iothub.this[0].event_hub_events_path}"
    IOTHUB_EVENTS_PATH       = azurerm_iothub.this[0].event_hub_events_path
    LARAVEL_URL              = "https://${azurerm_container_app.web.ingress[0].fqdn}"
    # Same trade-off as above: a plain app setting, because the vault is not reachable from here.
    LARAVEL_API_KEY = var.function_api_key
    # No SCM_DO_BUILD_DURING_DEPLOYMENT, ENABLE_ORYX_BUILD or FUNCTIONS_WORKER_RUNTIME: Flex
    # Consumption does not take them (the runtime is runtime_name) and builds remotely by itself.
  }

  lifecycle {
    # Two read-back differences that made every plan show a change after the apply:
    #  - Azure adds the hidden-link tag when the app is linked to Application Insights.
    #  - The provider does not read AzureWebJobsStorage back, although it is set on the app
    #    (checked on 25/11/2026 with az functionapp config appsettings list, names only).
    # Consequence: a rotated storage key will not reach the app by itself. Change the setting by hand.
    ignore_changes = [
      tags["hidden-link: /app-insights-resource-id"],
      app_settings["AzureWebJobsStorage"],
    ]

    precondition {
      condition     = var.function_api_key != null
      error_message = "Set function_api_key when enable_function is true."
    }
  }
}
