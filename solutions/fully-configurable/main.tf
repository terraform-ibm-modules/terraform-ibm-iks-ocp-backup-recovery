# Retrieve information about an existing VPC cluster
data "ibm_container_cluster_config" "cluster_config" {
  cluster_name_id   = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  config_dir        = "${path.module}/kubeconfig"
  endpoint_type     = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
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
  kube_type                    = "openshift"
  connection_id                = var.brs_connection_id
  ibmcloud_api_key             = var.ibmcloud_api_key
  # --- BRS Instance Details---
  brs_instance_guid   = var.brs_instance_guid
  brs_instance_region = var.region
  brs_endpoint_type   = "public"
  brs_tenant_id       = var.brs_tenant_id
  # --- Registration Details ---
  registration_name = var.cluster_id
  # --- Backup Policy ---
  policy            = var.policy
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
  # --- Data Source Connector (DSC) ---
  dsc_chart_uri          = var.dsc_chart_uri
  dsc_image_version      = var.dsc_image_version
  dsc_name               = var.dsc_name
  dsc_replicas           = var.dsc_replicas
  dsc_namespace          = var.dsc_namespace
  dsc_registration_token = var.dsc_registration_token
  # --- Registration Settings ---
  registration_images = {
    data_mover              = var.data_mover_image_uri
    velero                  = var.velero_image_uri
    velero_aws_plugin       = var.velero_aws_plugin_image_uri
    velero_openshift_plugin = var.velero_openshift_plugin_image_uri
  }
  enable_auto_protect = var.enable_auto_protect
}
