########################################################################################################################
# Input variables
########################################################################################################################

variable "ibmcloud_api_key" {
  type        = string
  description = "The IBM Cloud API key."
  sensitive   = true
}

variable "prefix" {
  type        = string
  nullable    = true
  description = "The prefix to add to all resources that this solution creates (e.g `prod`, `test`, `dev`). To skip using a prefix, set this value to null or an empty string. [Learn more](https://terraform-ibm-modules.github.io/documentation/#/prefix.md)."

  validation {
    # - null and empty string is allowed
    # - Must not contain consecutive hyphens (--): length(regexall("--", var.prefix)) == 0
    # - Starts with a lowercase letter: [a-z]
    # - Contains only lowercase letters (a–z), digits (0–9), and hyphens (-)
    # - Must not end with a hyphen (-): [a-z0-9]
    condition = (var.prefix == null || var.prefix == "" ? true :
      alltrue([
        can(regex("^[a-z][-a-z0-9]*[a-z0-9]$", var.prefix)),
        length(regexall("--", var.prefix)) == 0
      ])
    )
    error_message = "Prefix must begin with a lowercase letter and may contain only lowercase letters, digits, and hyphens '-'. It must not end with a hyphen('-'), and cannot contain consecutive hyphens ('--')."
  }

  validation {
    # must not exceed 16 characters in length
    condition     = var.prefix == null || var.prefix == "" ? true : length(var.prefix) <= 16
    error_message = "Prefix must not exceed 16 characters."
  }
}

variable "existing_resource_group_name" {
  type        = string
  description = "The name of an existing resource group to provision the resources. [Learn more](https://cloud.ibm.com/docs/account?topic=account-rgs&interface=ui#create_rgs) about how to create a resource group."
  default     = "Default"
}

variable "region" {
  type        = string
  description = "The region to provision all resources in. [Learn more](https://terraform-ibm-modules.github.io/documentation/#/region) about how to select different regions for different services."
  default     = "us-south"
}

variable "vpc_resource_tags" {
  type        = list(string)
  description = "Metadata labels describing this vpc deployment, i.e. test."
  default     = []
}

variable "cluster_resource_tags" {
  type        = list(string)
  description = "Metadata labels describing this cluster deployment, i.e. test."
  default     = []
}

variable "access_tags" {
  type        = list(string)
  description = "A list of access tags to apply to the resources created by the module."
  default     = []
}

##############################################################################
# VPC variables
##############################################################################

variable "address_prefix" {
  description = "The IP range that will be defined for the VPC for a certain location. Use only with manual address prefixes."
  type        = string
  default     = "10.10.10.0/24"
}

variable "zone" {
  type        = number
  description = "Specify the zone to which the cluster will be deployed."
  default     = 1
  validation {
    condition     = contains([1, 2, 3], var.zone)
    error_message = "Each region has only 3 zones."
  }
}

##############################################################################
# Cluster variables
##############################################################################

variable "cluster_name" {
  type        = string
  description = "The name of the new IBM Cloud OpenShift Cluster. If a `prefix` input variable is specified, it is added to this name in the `<prefix>-value` format."
  default     = "openshift"
}

variable "openshift_version" {
  type        = string
  description = "Version of the OCP cluster to provision."
  default     = "4.19"

  validation {
    condition     = tonumber(var.openshift_version) >= 4.16
    error_message = "Minimum supported OpenShift version is 4.16."
  }
}

variable "openshift_entitlement" {
  type        = string
  description = "Value that is applied to the entitlements for OCP cluster provisioning."
  default     = null
}

variable "cluster_ready_when" {
  type        = string
  description = "The cluster is ready based on one of the following:: MasterNodeReady (not recommended), OneWorkerNodeReady, Normal, IngressReady."
  default     = "IngressReady"
}

variable "workers_per_zone" {
  type        = number
  description = "Defines the number of worker nodes to provision in each zone for the default worker pool. Overall cluster must have at least 2 worker nodes."
  default     = 2

  validation {
    condition     = var.workers_per_zone >= 2
    error_message = "Minimum of 2 is allowed when using single zone."
  }
}

variable "machine_type" {
  type        = string
  description = "Specifies the machine type for the default worker pool. This determines the CPU, memory, and disk resources available to each worker node."
  default     = "cx2d.metal.96x192"
}

variable "operating_system" {
  type        = string
  description = "Provide the operating system for the worker nodes in the default worker pool."
  default     = "RHCOS"

  validation {
    condition     = var.operating_system == "RHCOS"
    error_message = "Invalid operating system. Allowed values is 'RHCOS'."
  }
}

variable "addons" {
  type = object({
    debug-tool = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
    image-key-synchronizer = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
    openshift-data-foundation = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
    vpc-file-csi-driver = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
    static-route = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
    cluster-autoscaler = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
    vpc-block-csi-driver = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
    ibm-storage-operator = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
    openshift-ai = optional(object({
      version         = optional(string)
      parameters_json = optional(string)
    }))
  })
  description = "Map of OCP cluster add-on versions to install (NOTE: The 'vpc-block-csi-driver' add-on is installed by default for VPC clusters and 'ibm-storage-operator' is installed by default in OCP 4.15 and later, however you can explicitly specify it here if you wish to choose a later version than the default one). For full list of all supported add-ons and versions, see https://cloud.ibm.com/docs/containers?topic=containers-supported-cluster-addon-versions."
  nullable    = false
  # See, https://github.com/IBM-Cloud/terraform-provider-ibm/issues/6290
  default = {
    openshift-data-foundation = {
      parameters_json = "{\"osdStorageClassName\":\"localblock\",\"odfDeploy\":\"true\",\"autoDiscoverDevices\":\"true\"}"
    }
    vpc-file-csi-driver = {
      version = "2.0"
    }
  }
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
