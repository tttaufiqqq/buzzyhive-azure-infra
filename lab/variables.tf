variable "subscription_id" {
  type        = string
  default     = null
  description = "Azure subscription ID. If null, ARM_SUBSCRIPTION_ID is used."
}

variable "use_oidc" {
  type        = bool
  default     = false
  description = "Sign in with an OIDC token (GitHub Actions). Leave false for az login."
}

variable "project" {
  type    = string
  default = "hive"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.project))
    error_message = "Use 2 to 8 lowercase letters or digits so storage and registry names stay valid."
  }
}

variable "project_tag" {
  type        = string
  default     = "buzzyhive"
  description = "Value of the project tag. Separate from var.project, which is a short prefix for resource names (Azure caps storage accounts at 24 characters)."
}

variable "env" {
  type    = string
  default = "lab"
}

variable "alert_email" {
  type        = string
  description = "Address that receives the alert-rule notifications."
}

# ---------- Feature toggles ----------

variable "enable_iot" {
  type        = bool
  default     = true
  description = "IoT Hub (free tier F1; only one per subscription)."
}

variable "iothub_location" {
  type        = string
  default     = "southeastasia"
  description = "Region of the IoT Hub. IoT Hub is not offered in Malaysia West (checked with az provider show -n Microsoft.Devices), so it goes to the nearest region that has it. Devices reach it over the internet, so it need not sit next to the rest."
}

variable "enable_function" {
  type        = bool
  default     = false
  description = "Azure Function app that forwards IoT Hub messages to Laravel. Needs enable_iot. Off by default: this repository creates the app but not the function code yet, and Consumption (Y1) quota can be zero on a new subscription."
}

variable "keep_web_and_ml_warm" {
  type        = bool
  default     = false
  description = "Run one replica of laravel-web and flask-ml at all times (min_replicas = 1) so cold starts do not skew a load test. Costs a little more while the lab is up."
}

variable "enable_ml" {
  type        = bool
  default     = false
  description = "Azure Machine Learning workspace and a compute cluster that scales to zero."
}

variable "ml_vm_size" {
  type        = string
  default     = "Standard_DS3_v2"
  description = "Training VM size. Check vCPU quota for the family first."
}

# ---------- Containers ----------

variable "images" {
  type = object({
    laravel = optional(string)
    flask   = optional(string)
  })
  default     = {}
  description = "Full image references in ACR. While null, a placeholder image is deployed so the platform can be tested before the real images exist."
}

variable "mysql_database" {
  type    = string
  default = "buzzyhive"
}

variable "mysql_admin_login" {
  type    = string
  default = "hiveadmin"
}

variable "app_secrets" {
  type        = map(string)
  default     = {}
  sensitive   = true
  description = "Extra app secrets stored in Key Vault, keyed by lowercase-hyphen name, for example pusher-app-secret. Each becomes an env var in the Laravel apps, upper-cased with underscores."
}

variable "function_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "API key the Function sends to /api/sensor-data. Required when enable_function is true."
}
