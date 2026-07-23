##############################################################################
# Input Variables
##############################################################################

variable "ibmcloud_api_key" {
  description = "The IBM Cloud API key"
  type        = string
  sensitive   = true
}

variable "prefix" {
  description = "Prefix for naming resources"
  type        = string
  default     = "bkp-rcv"
}

variable "region" {
  description = "IBM Cloud region where resources will be created"
  type        = string
  default     = "us-south"
}

variable "resource_group" {
  description = "Name of existing resource group to use. If null, a new resource group will be created."
  type        = string
  default     = null
}

variable "resource_tags" {
  description = "List of tags to apply to resources"
  type        = list(string)
  default     = ["terraform", "backup-recovery-example"]
}

variable "access_tags" {
  description = "List of access tags to apply to resources"
  type        = list(string)
  default     = []
}

##############################################################################
# Cluster Configuration
##############################################################################

variable "source_cluster_name_id" {
  description = "Name or ID of existing source cluster. If null, a new cluster will be created."
  type        = string
  default     = null
}

variable "target_cluster_name_id" {
  description = "Name or ID of existing target cluster. If null, a new cluster will be created."
  type        = string
  default     = null
}

variable "cluster_config_endpoint_type" {
  description = "The type of endpoint to use for cluster config access: 'default', 'private', 'vpe', or 'link'."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "private", "vpe", "link"], var.cluster_config_endpoint_type)
    error_message = "`cluster_config_endpoint_type` must be 'default', 'private', 'vpe', or 'link'."
  }
}

##############################################################################
# BRS Instance Configuration
##############################################################################

variable "existing_brs_instance_crn" {
  description = "CRN of existing Backup & Recovery Service instance. If null, a new instance will be created."
  type        = string
  default     = null
}

variable "brs_create_new_connection" {
  description = "Set to true to create a new data source connection, false to look up an existing connection."
  type        = bool
  default     = true
}

variable "source_connection_name" {
  description = "Custom name for source cluster connection. If null, a default name using prefix will be generated."
  type        = string
  default     = null
}

variable "target_connection_name" {
  description = "Custom name for target cluster connection. If null, a default name using prefix will be generated."
  type        = string
  default     = null
}

##############################################################################
# Recovery Configuration
##############################################################################

variable "enable_recovery" {
  description = "Enable automatic recovery after backup completion. Set to true to test single-shot backup+recovery flow."
  type        = bool
  default     = false
}

variable "recovery_mode" {
  description = "Recovery mode: 'same-cluster' or 'cross-cluster'. Use 'cross-cluster' to test recovery to target cluster."
  type        = string
  default     = "cross-cluster"

  validation {
    condition     = contains(["same-cluster", "cross-cluster"], var.recovery_mode)
    error_message = "recovery_mode must be either 'same-cluster' or 'cross-cluster'."
  }
}
