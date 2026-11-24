resource "azurerm_container_app_environment" "this" {
  # Azure adds a "Consumption" workload profile to every consumption-only environment;
  # the provider would otherwise plan to remove it on every run.
  lifecycle {
    ignore_changes = [workload_profile]
  }

  name                       = local.names.acae
  resource_group_name        = local.rg
  location                   = local.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = azurerm_subnet.aca.id
  tags                       = local.tags

  depends_on = [azurerm_subnet_network_security_group_association.aca]
}

locals {
  laravel_image = coalesce(var.images.laravel, local.placeholder_image)
  flask_image   = coalesce(var.images.flask, local.placeholder_image)

  # Secrets come from Key Vault through the managed identity and the private endpoint.
  kv_secret_ids = {
    for name in local.secret_names : name => "${azurerm_key_vault.this.vault_uri}secrets/${name}"
  }

  # Plain (non-secret) settings shared by every Laravel container.
  laravel_env = {
    APP_ENV                               = "production"
    DB_CONNECTION                         = "mysql"
    DB_HOST                               = azurerm_mysql_flexible_server.this.fqdn
    DB_PORT                               = "3306"
    DB_DATABASE                           = var.mysql_database
    DB_USERNAME                           = var.mysql_admin_login
    SESSION_DRIVER                        = "database"
    CACHE_STORE                           = "database"
    QUEUE_CONNECTION                      = "database"
    ML_URL                                = "http://flask-ml"                    # the name config/services.php reads
    LOG_CHANNEL                           = "stderr"                             # container logs go to Log Analytics
    TRUSTED_PROXIES                       = "*"                                  # ingress terminates TLS; see bootstrap/app.php
    MYSQL_ATTR_SSL_CA                     = "/etc/ssl/certs/ca-certificates.crt" # Azure MySQL requires TLS
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
  }

  # Secret name (lowercase, hyphens) to environment variable name.
  secret_env = { for name in local.secret_names : name => upper(replace(name, "-", "_")) }

  # Until real images exist, the placeholder runs with its own entrypoint.
  web_port   = local.use_placeholders ? 80 : 8080
  flask_port = local.use_placeholders ? 80 : 5000
}

# ---------- laravel-web: external ingress ----------

resource "azurerm_container_app" "web" {
  lifecycle {
    ignore_changes = [workload_profile_name] # set by Azure to "Consumption"
  }

  name                         = "laravel-web"
  resource_group_name          = local.rg
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = data.azurerm_user_assigned_identity.apps.id
  }

  dynamic "secret" {
    for_each = local.kv_secret_ids
    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = data.azurerm_user_assigned_identity.apps.id
    }
  }

  ingress {
    external_enabled = true
    target_port      = local.web_port

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.keep_web_and_ml_warm ? 1 : 0
    max_replicas = 1 # hive images and the thesis PDF live on container disk; see docs/docker.md

    container {
      name   = "laravel-web"
      image  = local.laravel_image
      cpu    = 0.5
      memory = "1Gi"

      dynamic "liveness_probe" {
        for_each = local.use_placeholders ? [] : [1]
        content {
          transport = "HTTP"
          port      = local.web_port
          path      = "/up"
        }
      }

      dynamic "env" {
        for_each = local.laravel_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env
        content {
          name        = env.value
          secret_name = env.key
        }
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_private_endpoint.kv,
    azapi_resource.secret,
  ]
}

# ---------- laravel-worker: queue, no ingress, always on ----------

resource "azurerm_container_app" "worker" {
  lifecycle {
    ignore_changes = [workload_profile_name] # set by Azure to "Consumption"
  }

  name                         = "laravel-worker"
  resource_group_name          = local.rg
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = data.azurerm_user_assigned_identity.apps.id
  }

  dynamic "secret" {
    for_each = local.kv_secret_ids
    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = data.azurerm_user_assigned_identity.apps.id
    }
  }

  template {
    min_replicas = 1 # alerts must not wait for a cold start
    max_replicas = 1

    container {
      name   = "laravel-worker"
      image  = local.laravel_image
      cpu    = 0.25
      memory = "0.5Gi"
      args   = local.use_placeholders ? null : ["php", "artisan", "queue:work", "--tries=3", "--max-time=3600"]

      dynamic "env" {
        for_each = local.laravel_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env
        content {
          name        = env.value
          secret_name = env.key
        }
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_private_endpoint.kv,
    azapi_resource.secret,
  ]
}

# ---------- flask-ml: internal ingress only ----------

resource "azurerm_container_app" "flask" {
  lifecycle {
    ignore_changes = [workload_profile_name] # set by Azure to "Consumption"
  }

  name                         = "flask-ml"
  resource_group_name          = local.rg
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = data.azurerm_user_assigned_identity.apps.id
  }

  ingress {
    external_enabled = false
    target_port      = local.flask_port

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.keep_web_and_ml_warm ? 1 : 0
    max_replicas = 2

    container {
      name   = "flask-ml"
      image  = local.flask_image
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "liveness_probe" {
        for_each = local.use_placeholders ? [] : [1]
        content {
          transport = "HTTP"
          port      = local.flask_port
          path      = "/health"
        }
      }
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}

# ---------- Jobs: scheduler and migrations ----------
# Neither runs inside the worker, or every replica would repeat them.

resource "azurerm_container_app_job" "scheduler" {
  lifecycle {
    ignore_changes = [workload_profile_name] # set by Azure to "Consumption"
  }

  count                        = local.use_placeholders ? 0 : 1 # the placeholder image never exits
  name                         = "laravel-schedule"
  resource_group_name          = local.rg
  location                     = local.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  replica_timeout_in_seconds   = 300
  replica_retry_limit          = 0
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = data.azurerm_user_assigned_identity.apps.id
  }

  dynamic "secret" {
    for_each = local.kv_secret_ids
    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = data.azurerm_user_assigned_identity.apps.id
    }
  }

  schedule_trigger_config {
    cron_expression          = "* * * * *"
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "schedule-run"
      image  = local.laravel_image
      cpu    = 0.25
      memory = "0.5Gi"
      args   = local.use_placeholders ? null : ["php", "artisan", "schedule:run"]

      dynamic "env" {
        for_each = local.laravel_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env
        content {
          name        = env.value
          secret_name = env.key
        }
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_private_endpoint.kv,
    azapi_resource.secret,
  ]
}

# Started by the pipeline before a new revision takes traffic:
#   az containerapp job start --name laravel-migrate --resource-group <rg>
resource "azurerm_container_app_job" "migrate" {
  lifecycle {
    ignore_changes = [workload_profile_name] # set by Azure to "Consumption"
  }

  count                        = local.use_placeholders ? 0 : 1 # the placeholder image never exits
  name                         = "laravel-migrate"
  resource_group_name          = local.rg
  location                     = local.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 0
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = data.azurerm_user_assigned_identity.apps.id
  }

  dynamic "secret" {
    for_each = local.kv_secret_ids
    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = data.azurerm_user_assigned_identity.apps.id
    }
  }

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "migrate"
      image  = local.laravel_image
      cpu    = 0.25
      memory = "0.5Gi"
      args   = local.use_placeholders ? null : ["php", "artisan", "migrate", "--force"]

      dynamic "env" {
        for_each = local.laravel_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env
        content {
          name        = env.value
          secret_name = env.key
        }
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_private_endpoint.kv,
    azapi_resource.secret,
  ]
}
