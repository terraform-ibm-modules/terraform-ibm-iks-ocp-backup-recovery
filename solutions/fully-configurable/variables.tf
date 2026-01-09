########################################################################################################################
# Input variables
########################################################################################################################

variable "ibmcloud_api_key" {
  type        = string
  description = "The IBM Cloud API key."
  sensitive   = true
}

##############################################################################
# Cluster variables
##############################################################################

variable "cluster_id" {
  type        = string
  description = "The ID of the cluster to deploy the agents in."
}

variable "cluster_resource_group_id" {
  type        = string
  description = "The resource group ID of the cluster."
}

variable "cluster_config_endpoint_type" {
  description = "Specify the type of endpoint to use to access the cluster configuration. Possible values: `default`, `private`, `vpe`, `link`. The `default` value uses the default endpoint of the cluster."
  type        = string
  default     = "default"
  nullable    = false # use default if null is passed in
}
variable "wait_till" {
  description = "To avoid long wait times when you run your Terraform code, you can specify the stage when you want Terraform to mark the cluster resource creation as completed. Depending on what stage you choose, the cluster creation might not be fully completed and continues to run in the background. However, your Terraform code can continue to run without waiting for the cluster to be fully created. Supported args are `MasterNodeReady`, `OneWorkerNodeReady`, `IngressReady` and `Normal`."
  type        = string
  default     = "Normal"
}

variable "wait_till_timeout" {
  description = "Timeout for wait_till in minutes."
  type        = number
  default     = 90
}
##############################################################
# Backup Related
##############################################################
variable "region" {
  type        = string
  description = "The region where the cluster is located."
  default     = "us-east"
}
variable "resource_tags" {
  type        = list(string)
  description = "A list of tags to apply to the resources created by the module."
  default     = []
}
variable "brs_instance_name" {
  type        = string
  description = "The name of the Backup and Recovery Service instance to create."
  default     = null
}

variable "brs_connection_name" {
  type        = string
  description = "The name of the Backup and Recovery Service connection to create."
  default     = null
}

variable "policy" {
  type = object({
    name = string
    schedule = optional(object({
      unit      = string # Minutes, Hours, Days, Weeks, Months, Years, Runs
      frequency = number # required when unit is Minutes/Hours/Days

      # Optional extra layers (allowed even when unit = Minutes)
      minute_schedule = optional(object({ frequency = number }))
      hour_schedule   = optional(object({ frequency = number }))
      day_schedule    = optional(object({ frequency = number }))
      week_schedule   = optional(object({ day_of_week = list(string) }))
      month_schedule = optional(object({
        day_of_week   = optional(list(string))
        week_of_month = optional(string) # First, Second, Third, Fourth, Last
        day_of_month  = optional(number)
      }))
      year_schedule = optional(object({ day_of_year = string })) # First, Last
    }))

    retention = optional(object({
      duration = number
      unit     = string # Days, Weeks, Months, Years

      data_lock_config = optional(object({
        mode                           = string # Compliance, Administrative
        unit                           = string # Days, Weeks, Months, Years
        duration                       = number
        enable_worm_on_external_target = optional(bool, false)
      }))
    }))

    use_default_backup_target = optional(bool, true)
  })
  default = {
    name = "default-policy"
    schedule = {
      unit      = "Hours"
      frequency = 6
    }
    retention = {
      duration = 4
      unit     = "Weeks"
    }
    use_default_backup_target = true
  }
  validation {
    condition = contains(["Gold", "Silver", "Bronze"], var.policy.name) ? (
      var.policy.schedule == null && var.policy.retention == null
      ) : (
      var.policy.schedule != null && var.policy.retention != null
    )
    error_message = "If using built-in policies (Gold, Silver, Bronze), do not provide schedule or retention. For custom policies, both are required."
  }
  description = "The backup schedule and retentions of a Protection Policy."
}
