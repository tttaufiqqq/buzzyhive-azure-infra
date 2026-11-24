variable "subscription_id" {
  type        = string
  default     = null
  description = "Azure subscription ID. If null, ARM_SUBSCRIPTION_ID is used."
}

variable "location" {
  type        = string
  default     = "malaysiawest"
  description = "Azure region for the state storage account."
}

variable "project" {
  type        = string
  default     = "hive"
  description = "Short project name used in resource names and tags."

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.project))
    error_message = "Use 2 to 8 lowercase letters or digits so the storage account name stays within 24 characters."
  }
}

variable "project_tag" {
  type        = string
  default     = "buzzyhive"
  description = "Value of the project tag. Separate from var.project, which is a short prefix for resource names (Azure caps storage accounts at 24 characters)."
}

variable "env" {
  type        = string
  default     = "lab"
  description = "Environment tag."
}
