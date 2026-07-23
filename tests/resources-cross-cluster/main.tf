##############################################################################
# Resource Group
##############################################################################

module "resource_group" {
  source                       = "terraform-ibm-modules/resource-group/ibm"
  version                      = "1.6.0"
  resource_group_name          = var.resource_group == null ? "${var.prefix}-resource-group" : null
  existing_resource_group_name = var.resource_group
}

locals {
  existing_brs_instance_crn = var.existing_brs_instance_crn == "" ? null : var.existing_brs_instance_crn
  brs_region                = local.existing_brs_instance_crn != null ? module.crn_parser[0].region : var.region
}

module "crn_parser" {
  source  = "terraform-ibm-modules/common-utilities/ibm//modules/crn-parser"
  version = "1.5.0"
  count   = local.existing_brs_instance_crn == null ? 0 : 1
  crn     = local.existing_brs_instance_crn
}

# Pre-provision Source Connection in existing BRS instance
module "source_connection" {
  source                    = "terraform-ibm-modules/backup-recovery/ibm"
  version                   = "1.12.3"
  region                    = local.brs_region
  resource_group_id         = module.resource_group.resource_group_id
  ibmcloud_api_key          = var.ibmcloud_api_key
  resource_tags             = var.resource_tags
  instance_name             = "${var.prefix}-brs-instance"
  connection_name           = "${var.prefix}-source-connection"
  create_new_connection     = true
  connection_env_type       = "kIksVpc"
  existing_brs_instance_crn = local.existing_brs_instance_crn
  policies                  = []
}

# Pre-provision Target Connection in existing BRS instance
module "target_connection" {
  source                    = "terraform-ibm-modules/backup-recovery/ibm"
  version                   = "1.12.3"
  region                    = local.brs_region
  resource_group_id         = module.resource_group.resource_group_id
  ibmcloud_api_key          = var.ibmcloud_api_key
  resource_tags             = var.resource_tags
  instance_name             = "${var.prefix}-brs-instance"
  connection_name           = "${var.prefix}-target-connection"
  create_new_connection     = true
  connection_env_type       = "kIksVpc"
  existing_brs_instance_crn = local.existing_brs_instance_crn
  create_new_instance       = false
  policies                  = []
}
