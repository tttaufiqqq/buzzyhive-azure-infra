# IoT Hub (free tier) and the Function that forwards each message to Laravel.
# IoT Hub and the Function sit outside the VNet; the Function calls the public
# laravel-web ingress with the API key.

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
  count               = var.enable_iot && var.enable_function ? 1 : 0
  name                = "function"
  resource_group_name = local.rg
  iothub_name         = azurerm_iothub.this[0].name
  service_connect     = true
}

resource "azurerm_service_plan" "function" {
  count               = var.enable_iot && var.enable_function ? 1 : 0
  name                = local.names.plan
  resource_group_name = local.rg
  location            = local.location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption. Quota can be zero on a new subscription.
  tags                = local.tags
}

resource "azurerm_linux_function_app" "forwarder" {
  count                      = var.enable_iot && var.enable_function ? 1 : 0
  name                       = local.names.func
  resource_group_name        = local.rg
  location                   = local.location
  service_plan_id            = azurerm_service_plan.function[0].id
  storage_account_name       = azurerm_storage_account.public.name
  storage_account_access_key = azurerm_storage_account.public.primary_access_key
  tags                       = local.tags

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string

    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    # Event Hub-compatible endpoint of the IoT Hub, read by the IoT Hub trigger.
    IOTHUB_EVENTS_CONNECTION = "Endpoint=${azurerm_iothub.this[0].event_hub_events_endpoint};SharedAccessKeyName=${azurerm_iothub_shared_access_policy.function[0].name};SharedAccessKey=${azurerm_iothub_shared_access_policy.function[0].primary_key};EntityPath=${azurerm_iothub.this[0].event_hub_events_path}"
    LARAVEL_URL              = "https://${azurerm_container_app.web.ingress[0].fqdn}"
    LARAVEL_API_KEY          = var.function_api_key
  }

  lifecycle {
    precondition {
      condition     = var.function_api_key != null
      error_message = "Set function_api_key when enable_function is true."
    }
  }
}
