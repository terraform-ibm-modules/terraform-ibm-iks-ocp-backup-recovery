##############################################################################
# Authentication
##############################################################################

variable "ibmcloud_api_key" {
  type        = string
  description = "IBM Cloud API key. All resources (cluster, VPC, BRS instance, VPEG) are created in this account."
  sensitive   = true
}

##############################################################################
# Region / naming
##############################################################################

variable "region" {
  type        = string
  description = "IBM Cloud region for all resources."
  default     = "us-south"
}

variable "prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this example."
  validation {
    condition     = can(regex("^([A-Za-z]|[A-Za-z][-a-z0-9]*[a-z0-9])$", var.prefix))
    error_message = "Prefix must begin and end with a letter and contain only letters, numbers, and hyphens."
  }
}

variable "resource_group" {
  type        = string
  description = "Existing resource group name to use. If null a new resource group is created."
  default     = null
}

##############################################################################
# Cluster
##############################################################################

variable "cluster_name_id" {
  type        = string
  description = "Name or ID of an existing IKS VPC cluster to protect. Leave null (default) to create a new VPC and cluster."
  default     = null
}

variable "cluster_config_endpoint_type" {
  type        = string
  description = "Cluster config endpoint type: 'default', 'private', 'vpe', or 'link'."
  default     = "default"

  validation {
    condition     = contains(["default", "private", "vpe", "link"], var.cluster_config_endpoint_type)
    error_message = "Must be 'default', 'private', 'vpe', or 'link'."
  }
}

##############################################################################
# BRS VPE
##############################################################################

variable "create_brs_vpe" {
  type        = bool
  description = "Set to true to create the BRS VPE Gateway."
  default     = true
  nullable    = false
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for the BRS VPE Gateway. Required only when cluster_name_id is set (existing cluster) and create_brs_vpe is true."
  default     = null
}

variable "vpc_subnets" {
  type = list(object({
    name = string
    id   = string
    zone = string
  }))
  description = "Subnet list for the BRS VPE Gateway. Required only when cluster_name_id is set (existing cluster) and create_brs_vpe is true."
  default     = []
  nullable    = false
}

##############################################################################
# BRS instance
##############################################################################

variable "existing_brs_instance_crn" {
  type        = string
  description = "CRN of an existing BRS instance. If null a new BRS instance is created in var.region."
  default     = null
}

##############################################################################
# Workload / protection
##############################################################################

variable "workload_namespace" {
  type        = string
  description = "Kubernetes namespace to create for the test workload. Also used as the BRS protection-group object name."
  default     = "brs-testing-10g"
}

##############################################################################
# Tags
##############################################################################

variable "resource_tags" {
  type        = list(string)
  description = "Optional list of user tags to attach to all provisioned resources."
  default     = []
}

variable "access_tags" {
  type        = list(string)
  description = "Optional list of access management tags to apply to all provisioned resources."
  default     = []
}
