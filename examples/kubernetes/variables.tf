########################################################################################################################
# Input variables
########################################################################################################################
variable "ibmcloud_api_key" {
  type        = string
  description = "The IBM Cloud API Key."
  sensitive   = true
}

variable "resource_group" {
  type        = string
  description = "An existing resource group name to use for this example, if unset a new resource group will be created"
  default     = null
}

variable "prefix" {
  type        = string
  description = "Prefix for name of all resource created by this example"
  validation {
    error_message = "Prefix must begin and end with a letter and contain only letters, numbers, and - characters."
    condition     = can(regex("^([A-z]|[a-z][-a-z0-9]*[a-z0-9])$", var.prefix))
  }
}

variable "resource_tags" {
  type        = list(string)
  description = "Optional list of tags to be added to created resources"
  default     = []
}

variable "access_tags" {
  type        = list(string)
  description = "A list of access tags to apply to the resources created by the module."
  default     = []
}

variable "region" {
  type        = string
  description = "Region where resources are created."
  default     = "us-east"
}

variable "cluster_name_id" {
  type        = string
  description = <<EOT
Name or ID of the existing Kubernetes cluster to protect.
If left empty (null, which is the default), this example will automatically create a new VPC
and provision a Kubernetes cluster for you.
If you provide a value, the module will use that existing cluster instead of creating a new one.
EOT
  default     = null
}

variable "dsc_storage_class" {
  type        = string
  description = "Storage class to use for the Data Source Connector persistent volume. By default, it uses 'ibmc-vpc-block-metro-5iops-tier' for VPC clusters and 'ibmc-block-silver' for Classic clusters."
  default     = null
}

variable "existing_brs_instance_crn" {
  type        = string
  description = "CRN of an existing BRS instance to use. If not provided, a new instance will be created."
  default     = null
}

variable "classic_cluster" {
  type        = bool
  description = "Set to true to provision a Classic cluster, false to provision a VPC cluster."
  default     = false
}

variable "datacenter" {
  type        = string
  description = "The classic infrastructure datacenter where the cluster is created. Only used if classic_cluster is true."
  default     = "dal10"
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
# VPE Gateway configuration (VPC clusters only)
##############################################################################

variable "create_brs_vpe" {
  description = "Set to true to create a Virtual Private Endpoint Gateway (VPEG) in the cluster VPC, routing DSC→BRS traffic over the IBM private backbone. Only effective for VPC clusters — ignored when classic_cluster is true."
  type        = bool
  default     = true
}

variable "brs_vpe_name" {
  description = "Override the name of the BRS VPE Gateway. If null, the name is auto-generated from the BRS connection name."
  type        = string
  default     = null
}

variable "brs_endpoint_type" {
  description = "Endpoint type used by Terraform and scripts to reach the BRS API: 'public' or 'private'. Set to 'public' (default) so that CI/workstation machines can reach the BRS API directly. DSC pods always communicate with BRS over the VPE Gateway regardless of this setting."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.brs_endpoint_type)
    error_message = "`brs_endpoint_type` must be 'public' or 'private'."
  }
}
