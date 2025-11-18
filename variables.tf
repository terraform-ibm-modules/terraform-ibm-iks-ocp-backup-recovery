##############################################################################
# Cluster variables
##############################################################################

variable "cluster_id" {
  type        = string
  description = "The ID of the cluster to deploy the agent."
}

variable "cluster_resource_group_id" {
  type        = string
  description = "The resource group ID of the cluster."
}

variable "cluster_config_endpoint_type" {
  description = "The type of endpoint to use for the cluster config access: `default`, `private`, `vpe`, or `link`. The `default` value uses the default endpoint of the cluster."
  type        = string
  default     = "default"
  nullable    = false # use default if null is passed in
  validation {
    error_message = "Invalid endpoint type. Valid values are `default`, `private`, `vpe`, or `link`."
    condition     = contains(["default", "private", "vpe", "link"], var.cluster_config_endpoint_type)
  }
}

variable "kube_type" {
  description = "Specify true if the target cluster for the agent is a VPC cluster, false if it is a classic cluster."
  type        = string
  default     = "ROKS"
  validation {
    condition = contains([
      "ROKS",
      "IKS",
    ], var.kube_type)
    error_message = "Accepted values are : ROKS or IKS"
  }
}

# variable "wait_till" {
#   description = "To avoid long wait times when you run your Terraform code, you can specify the stage when you want Terraform to mark the cluster resource creation as completed. Depending on what stage you choose, the cluster creation might not be fully completed and continues to run in the background. However, your Terraform code can continue to run without waiting for the cluster to be fully created. Supported args are `MasterNodeReady`, `OneWorkerNodeReady`, `IngressReady` and `Normal`"
#   type        = string
#   default     = "Normal"

#   validation {
#     error_message = "`wait_till` value must be one of `MasterNodeReady`, `OneWorkerNodeReady`, `IngressReady` or `Normal`."
#     condition = contains([
#       "MasterNodeReady",
#       "OneWorkerNodeReady",
#       "IngressReady",
#       "Normal"
#     ], var.wait_till)
#   }
# }

# variable "wait_till_timeout" {
#   description = "Timeout for wait_till in minutes."
#   type        = number
#   default     = 90
# }

##############################################################################
# Data Source Connector (BRS)
##############################################################################

variable "add_dsc_rules_to_cluster_sg" {
  type        = bool
  description = "Set to true to automatically add required security group rules for the Data Source Connector. Set to false to only register the cluster and create the policy."
  default     = true
}

variable "dsc_chart" {
  description = "Name of the Data Source Connector Helm chart."
  type        = string
  default     = "cohesity-dsc-chart"
  nullable    = false
}

variable "dsc_chart_location" {
  description = "OCI registry location of the Data Source Connector Helm chart."
  type        = string
  default     = "oci://icr.io/ext/brs" # Public registry - no authentication required
  nullable    = false
}

variable "dsc_chart_version" {
  description = "Version of the Data Source Connector Helm chart to deploy."
  type        = string
  default     = "7.2.15-release-20250721-6aa24701"
  nullable    = false
}

variable "dsc_image" {
  description = "Container image for the Data Source Connector."
  type        = string
  default     = "icr.io/ext/brs/cohesity-data-source-connector_7.2.15-release-20250721"
  nullable    = false
}

variable "dsc_image_version_tag" {
  description = "Image tag for the Data Source Connector container."
  type        = string
  default     = "6aa24701"
  nullable    = false
}

variable "dsc_name" {
  description = "Release name for the Data Source Connector Helm deployment."
  type        = string
  default     = "dsc"
  nullable    = false
}

variable "dsc_replicas" {
  description = "Number of Data Source Connector pods to run (typically 1)."
  type        = number
  default     = 1
  nullable    = false
}

variable "dsc_namespace" {
  type        = string
  description = "Kubernetes namespace where the Data Source Connector will be installed. Will be created if it does not exist."
  default     = "data-source-connector"
  nullable    = false
}

variable "dsc_registration_token" {
  type        = string
  description = "Registration token generated in the Backup & Recovery Service UI when adding a Kubernetes data source."
  sensitive   = true
  nullable    = false
}

##############################################################################
# Backup Recovery Service Instance
##############################################################################

variable "connection_id" {
  type        = string
  description = "Connection ID for the backup service"
}

variable "brs_instance_guid" {
  type        = string
  description = "GUID of the Backup & Recovery Service instance."
  nullable    = false
}

variable "brs_instance_region" {
  type        = string
  description = "Region of the Backup & Recovery Service instance."
  nullable    = false
}

variable "brs_endpoint_type" {
  type        = string
  description = "The endpoint type to use when connecting to the Backup and Recovery service for creating a data source connection. Allowed values are 'public' or 'private'."
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.brs_endpoint_type)
    error_message = "endpoint_type must be 'public' or 'private'."
  }
}

variable "brs_tenant_id" {
  type        = string
  description = "BRS tenant ID in the format `<tenant-guid>/`. Required for API calls and agent configuration."
  nullable    = false
}

variable "registration_name" {
  type        = string
  description = "Name of the registration."
  nullable    = false
}

variable "registration_images" {
  type = object({
    data_mover              = optional(string, null)
    velero                  = optional(string, null)
    velero_aws_plugin       = optional(string, null)
    velero_openshift_plugin = optional(string, null)
    init_container          = optional(string, null)
  })
  default     = {}
  description = "value"
}

variable "policy" {
  type = object({
    name = string
    schedule = object({
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
    })

    retention = object({
      duration = number
      unit     = string # Days, Weeks, Months, Years

      data_lock_config = optional(object({
        mode                           = string # Compliance, Administrative
        unit                           = string # Days, Weeks, Months, Years
        duration                       = number
        enable_worm_on_external_target = optional(bool, false)
      }))
    })

    use_default_backup_target = optional(bool, true)
  })

  description = "IBM Backup & Recovery Protection Policy – fully validated"
}
