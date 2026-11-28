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

variable "region" {
  type        = string
  description = "Region where resources are created."
  default     = "us-east"
}

variable "access_tags" {
  type        = list(string)
  description = "A list of access tags to apply to the resources created by the module."
  default     = []
}

variable "ocp_version" {
  type        = string
  description = "Version of the OCP cluster to provision"
  default     = null
}

variable "ocp_entitlement" {
  type        = string
  description = "Value that is applied to the entitlements for OCP cluster provisioning"
  default     = null
}

variable "dsc_storage_class" {
  type        = string
  description = "Storage class to use for the Data Source Connector persistent volume. By default, it uses 'ibmc-vpc-block-metro-5iops-tier'."
  default     = null
}

variable "existing_brs_instance_crn" {
  type        = string
  description = "CRN of an existing BRS instance to use. If not provided, a new instance will be created."
  default     = null
}

variable "cluster_config_endpoint_type" {
  description = "The type of endpoint to use for cluster config access: 'default', 'private', 'vpe', or 'link'. This example creates a cluster with no public endpoint, so the default is 'private'. The machine running Terraform must be able to reach the cluster private endpoint."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["default", "private", "vpe", "link"], var.cluster_config_endpoint_type)
    error_message = "`cluster_config_endpoint_type` must be 'default', 'private', 'vpe', or 'link'."
  }
}

variable "brs_endpoint_type" {
  description = "Endpoint type used by Terraform and scripts to reach the BRS API: 'public' or 'private'. Set to 'public' (default) so that the workstation running Terraform can reach the BRS API directly. The Data Source Connector always communicates with BRS over the VPE Gateway regardless of this setting."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.brs_endpoint_type)
    error_message = "`brs_endpoint_type` must be 'public' or 'private'."
  }
}

variable "datamover_service_type" {
  description = "Service type used for datamover communication during source registration. Allowed values are 'kHostPort', 'kNodePort', 'kLoadBalancer' and 'kClusterIp'."
  type        = string
  default     = "kHostPort"

  validation {
    condition     = contains(["kHostPort", "kNodePort", "kLoadBalancer", "kClusterIp"], var.datamover_service_type)
    error_message = "`datamover_service_type` must be one of 'kHostPort', 'kNodePort', 'kLoadBalancer', or 'kClusterIp'."
  }
}
