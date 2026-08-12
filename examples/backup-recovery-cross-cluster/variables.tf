##############################################################################
# Input Variables
##############################################################################

variable "ibmcloud_api_key" {
  description = "IBM Cloud API key. Used for both the BRS instance (ibm provider) and the cluster resources (ibm.cluster provider = ibm — same account)."
  type        = string
  sensitive   = true
}

variable "prefix" {
  description = "Prefix applied to all resource names created by this example."
  type        = string
  default     = "bkp-rcv"

  validation {
    condition     = can(regex("^([A-Za-z]|[A-Za-z][-a-z0-9]*[a-z0-9])$", var.prefix))
    error_message = "Prefix must begin and end with a letter and contain only letters, numbers, and hyphens."
  }
}

variable "region" {
  description = "IBM Cloud region where all resources will be created."
  type        = string
  default     = "us-south"
}

variable "resource_group" {
  description = "Existing resource group name to use for all resources. If null, a new resource group is created."
  type        = string
  default     = null
}

variable "resource_tags" {
  description = "Optional list of user tags to attach to all provisioned resources."
  type        = list(string)
  default     = []
}

variable "access_tags" {
  description = "Optional list of access management tags to apply to all provisioned resources."
  type        = list(string)
  default     = []
}

##############################################################################
# Cluster configuration
##############################################################################

variable "source_cluster_name_id" {
  description = "Name or ID of an existing source IKS VPC cluster. Leave null (default) to create a new VPC and cluster."
  type        = string
  default     = null
}

variable "target_cluster_name_id" {
  description = "Name or ID of an existing target IKS VPC cluster. Leave null (default) to create a new VPC and cluster."
  type        = string
  default     = null
}

variable "cluster_config_endpoint_type" {
  description = "Cluster config endpoint type: 'default', 'private', 'vpe', or 'link'."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "private", "vpe", "link"], var.cluster_config_endpoint_type)
    error_message = "`cluster_config_endpoint_type` must be 'default', 'private', 'vpe', or 'link'."
  }
}

##############################################################################
# BRS instance configuration
##############################################################################

variable "existing_brs_instance_crn" {
  description = "CRN of an existing Backup & Recovery Service instance. If null, a new instance is created by the source module and shared with the target module."
  type        = string
  default     = null
}

variable "source_connection_name" {
  description = "Custom connection name for the source cluster. If null, '<prefix>-source-connection' is used."
  type        = string
  default     = null
}

variable "target_connection_name" {
  description = "Custom connection name for the target cluster. If null, '<prefix>-target-connection' is used."
  type        = string
  default     = null
}

##############################################################################
# Recovery configuration
##############################################################################

variable "enable_recovery" {
  description = "Set to true to trigger a cross-cluster recovery automatically after the first backup run completes. Useful for a single-shot backup+restore test in one apply."
  type        = bool
  default     = false
}

variable "recovery_mode" {
  description = "Recovery mode: 'same-cluster' to restore within the source cluster, 'cross-cluster' to restore to the target cluster."
  type        = string
  default     = "cross-cluster"

  validation {
    condition     = contains(["same-cluster", "cross-cluster"], var.recovery_mode)
    error_message = "recovery_mode must be either 'same-cluster' or 'cross-cluster'."
  }
}
