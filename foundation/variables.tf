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
}

variable "env" {
  type    = string
  default = "lab"
}

variable "location" {
  type        = string
  default     = "southeastasia"
  description = "Region of the resource group."
}

variable "allowed_locations" {
  type        = list(string)
  default     = ["southeastasia", "malaysiawest", "global"]
  description = "Regions the audit policy treats as allowed."
}

variable "enable_locks" {
  type        = bool
  default     = false
  description = "CanNotDelete lock on the resource group. Keep false in the lab, or terraform destroy in lab/ fails."
}

variable "alert_emails" {
  type        = list(string)
  description = "Addresses that receive budget alerts."

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "Provide at least one address."
  }
}

variable "budget_amount" {
  type        = number
  default     = 100
  description = "Monthly budget in USD. Keep it below the credit that is left ($135.68 when this was written)."
}

variable "budget_start_date" {
  type        = string
  description = "First day of a month in RFC 3339, for example 2026-11-01T00:00:00Z."
}

variable "budget_thresholds" {
  type    = list(number)
  default = [75, 90]
}

variable "github_owner" {
  type        = string
  description = "GitHub user or organisation that owns the infrastructure repository."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name."
}

variable "github_environment" {
  type        = string
  default     = "lab"
  description = "GitHub environment that applies are approved in."
}

variable "state_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the state storage account (bootstrap output)."
}

variable "state_storage_account_name" {
  type        = string
  default     = null
  description = "State storage account name (bootstrap output). Set to give the pipeline access to state."
}
