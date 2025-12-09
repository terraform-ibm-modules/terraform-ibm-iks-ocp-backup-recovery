##############################################################################
# Resource Group
##############################################################################
module "resource_group" {
  source                       = "terraform-ibm-modules/resource-group/ibm"
  version                      = "1.4.0"
  resource_group_name          = var.resource_group == null ? "${var.prefix}-resource-group" : null
  existing_resource_group_name = var.resource_group
}

##############################################################################
# Get Kubernetes cluster by name
##############################################################################

data "ibm_container_vpc_cluster" "cluster" {
  name              = var.cluster_name_id
  resource_group_id = module.resource_group.resource_group_id
}

data "ibm_container_cluster_config" "cluster_config" {
  cluster_name_id   = data.ibm_container_vpc_cluster.cluster.id
  resource_group_id = module.resource_group.resource_group_id
  admin             = true
}

########################################################################################################################
# Backup & Recovery Service (BRS)
########################################################################################################################

module "backup_recovery_instance" {
  source                = "terraform-ibm-modules/backup-recovery/ibm"
  version               = "v1.1.0"
  region                = var.region
  resource_group_id     = module.resource_group.resource_group_id
  ibmcloud_api_key      = var.ibmcloud_api_key
  tags                  = var.resource_tags
  instance_name         = "${var.prefix}-brs-instance"
  connection_name       = "${var.prefix}-brs-connection"
  create_new_connection = true
  create_new_instance   = true
}


########################################################################################################################
# Backup & Recovery for IKS/ROKS with Data Source Connector
########################################################################################################################


module "backup_recover_protect_ocp" {
  source                    = "../.."
  cluster_id                = data.ibm_container_vpc_cluster.cluster.id
  cluster_resource_group_id = module.resource_group.resource_group_id
  dsc_registration_token    = module.backup_recovery_instance.registration_token
  kube_type                 = "kubernetes"
  connection_id             = module.backup_recovery_instance.connection_id
  # --- B&R Instance ---
  brs_instance_guid   = module.backup_recovery_instance.brs_instance_guid
  brs_instance_region = var.region
  brs_endpoint_type   = "public"
  brs_tenant_id       = module.backup_recovery_instance.tenant_id
  registration_name   = data.ibm_container_vpc_cluster.cluster.name
  # --- Backup Policy ---
  policy = {
    name = "${var.prefix}-retention"
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
}
