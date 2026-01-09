
variable "ibmcloud_api_key" {
  type        = string
  description = "The IBM Cloud API key."
  sensitive   = true
}

variable "existing_resource_group_name" {
  type        = string
  description = "The name of an existing resource group to provision the resources. [Learn more](https://cloud.ibm.com/docs/account?topic=account-rgs&interface=ui#create_rgs) about how to create a resource group."
  default     = "Default"
}

variable "provider_visibility" {
  description = "Set the visibility value for the IBM terraform provider. [Learn more](https://registry.terraform.io/providers/IBM-Cloud/ibm/latest/docs/guides/custom-service-endpoints)."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["public", "private", "public-and-private"], var.provider_visibility)
    error_message = "Invalid visibility option. Allowed values are 'public', 'private', or 'public-and-private'."
  }
}

variable "prefix" {
  type        = string
  description = "The prefix to add to all resources that this solution creates (e.g `prod`, `test`, `dev`). To skip using a prefix, set this value to null or an empty string. [Learn more](https://terraform-ibm-modules.github.io/documentation/#/prefix.md)."
  nullable    = true
  validation {
    condition = (var.prefix == null || var.prefix == "" ? true :
      alltrue([
        can(regex("^[a-z][-a-z0-9]*[a-z0-9]$", var.prefix)),
        length(regexall("--", var.prefix)) == 0
      ])
    )
    error_message = "Prefix must begin with a lowercase letter and may contain only lowercase letters, digits, and hyphens '-'. It must not end with a hyphen('-'), and cannot contain consecutive hyphens ('--')."
  }
  validation {
    condition     = var.prefix == null || var.prefix == "" ? true : length(var.prefix) <= 16
    error_message = "Prefix must not exceed 16 characters."
  }
}

variable "region" {
  type        = string
  description = "Region in which all the resources will be deployed. [Learn More](https://terraform-ibm-modules.github.io/documentation/#/region)."
  default     = "us-east"
}

variable "openshift_version" {
  type        = string
  description = "Version of the OpenShift cluster to provision."
  default     = null
}

variable "cluster_name" {
  type        = string
  description = "The name of the new IBM Cloud OpenShift Cluster. If a `prefix` input variable is specified, it is added to this name in the `<prefix>-value` format."
  default     = "cluster"
}

variable "address_prefix" {
  description = "The IP range that defines a certain location for the VPC. Use only with manual address prefixes."
  type        = string
  default     = "10.10.10.0/24"
}

variable "ocp_entitlement" {
  type        = string
  description = "Value that is applied to the entitlements for OCP cluster provisioning."
  default     = null
}

variable "default_worker_pool_operating_system" {
  type        = string
  description = "The operating system installed on the worker nodes. [Learn more](https://cloud.ibm.com/docs/openshift?topic=openshift-vpc-flavors)."
  default     = "RHCOS"
}

variable "access_tags" {
  type        = list(string)
  description = "A list of access tags to apply to the resources created by the module."
  default     = []
}

variable "size" {
  type        = string
  description = "Defines the cluster size configuration. [Learn more](https://github.com/terraform-ibm-modules/terraform-ibm-iks-ocp-backup-recovery/blob/main/solutions/quickstart/DA_docs.md)."
  default     = "mini"
}

variable "allow_public_access_to_cluster_management" {
  type        = bool
  description = "Set to true to access the cluster through a public cloud service endpoint. [Learn More](https://cloud.ibm.com/docs/openshift?topic=openshift-access_cluster)."
  default     = true
}

variable "allow_outbound_traffic" {
  type        = bool
  description = "Set to true to allow public outbound access from the cluster workers."
  default     = true
}

##############################################################
# Backup Related
##############################################################
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
