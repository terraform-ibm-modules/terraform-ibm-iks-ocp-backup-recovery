# Retrieve information about an existing VPC cluster
data "ibm_container_cluster_config" "cluster_config" {
  cluster_name_id   = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  config_dir        = "${path.module}/kubeconfig"
  endpoint_type     = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
}

########################################################################################################################
# Backup & Recovery Service (BRS)
########################################################################################################################

module "backup_recovery_instance" {
  source                = "terraform-ibm-modules/backup-recovery/ibm"
  version               = "v1.1.10"
  region                = var.region
  resource_group_id     = var.cluster_resource_group_id
  ibmcloud_api_key      = var.ibmcloud_api_key
  tags                  = var.resource_tags
  instance_name         = var.brs_instance_name
  connection_name       = var.brs_connection_name
  create_new_connection = true
  create_new_instance   = true
}


########################################################################################################################
# Backup & Recovery for IKS/ROKS with Data Source Connector
########################################################################################################################


module "protect_cluster" {
  source                       = "../.."
  cluster_id                   = var.cluster_id
  cluster_resource_group_id    = var.cluster_resource_group_id
  cluster_config_endpoint_type = "private"
  add_dsc_rules_to_cluster_sg  = false
  dsc_registration_token       = module.backup_recovery_instance.registration_token
  kube_type                    = "openshift"
  connection_id                = module.backup_recovery_instance.connection_id
  ibmcloud_api_key             = var.ibmcloud_api_key
  # --- B&R Instance ---
  brs_instance_guid   = module.backup_recovery_instance.brs_instance_guid
  brs_instance_region = var.region
  brs_endpoint_type   = "public"
  brs_tenant_id       = module.backup_recovery_instance.tenant_id
  registration_name   = var.cluster_id
  # --- Backup Policy ---
  policy            = var.policy
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}
