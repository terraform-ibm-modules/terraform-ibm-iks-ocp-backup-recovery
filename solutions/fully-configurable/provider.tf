########################################################################################################################
# Provider config
#
# Three deployment modes are supported:
#
#   Same-account (source_ibmcloud_api_key = null, the default)
#     All three ibm providers share ibmcloud_api_key. BRS instance, source cluster,
#     and target cluster all live in the same account and region.
#
#   Cross-account (source_ibmcloud_api_key set)
#     ibm                → BRS account  (ibmcloud_api_key)
#                          BRS instance, connection, S2S IAM authorization policy.
#     ibm.source_cluster → source account (source_ibmcloud_api_key)
#                          Source cluster, source VPC/subnet/SG/VPE, DSC Helm chart.
#     ibm.target_cluster → same as ibm.source_cluster when target_ibmcloud_api_key is null.
#
#   Three-account (source_ibmcloud_api_key and target_ibmcloud_api_key both set)
#     ibm                → BRS account          (ibmcloud_api_key)
#     ibm.source_cluster → source cluster account (source_ibmcloud_api_key / source_cluster_region)
#     ibm.target_cluster → target cluster account (target_ibmcloud_api_key / target_cluster_region)
#
# The kubernetes and helm providers always point at the respective cluster kubeconfig.
########################################################################################################################

# Default provider — target (BRS) account, or only account in same-account mode.
provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  visibility       = var.provider_visibility
}

# Source-cluster provider alias — source cluster account and region.
# When source_ibmcloud_api_key is null (same-account), falls back to ibmcloud_api_key.
# Carries Classic Infrastructure credentials for kIksClassic / kRoksClassic source clusters.
provider "ibm" {
  alias                 = "source_cluster"
  ibmcloud_api_key      = var.source_ibmcloud_api_key != null ? var.source_ibmcloud_api_key : var.ibmcloud_api_key
  iaas_classic_username = var.iaas_classic_username
  iaas_classic_api_key  = var.iaas_classic_api_key
  region                = var.source_cluster_region != null ? var.source_cluster_region : var.region
  visibility            = var.provider_visibility
}

# Target-cluster provider alias — target cluster account and region.
# When target_ibmcloud_api_key is null, falls back to source_ibmcloud_api_key → ibmcloud_api_key.
# When target_cluster_region is null, falls back to source_cluster_region → region.
# In same-region same-account deployments this alias is identical to ibm.source_cluster.
# No Classic Infrastructure credentials — Classic target clusters are not supported.
provider "ibm" {
  alias            = "target_cluster"
  ibmcloud_api_key = var.target_ibmcloud_api_key != null ? var.target_ibmcloud_api_key : (var.source_ibmcloud_api_key != null ? var.source_ibmcloud_api_key : var.ibmcloud_api_key)
  region           = var.target_cluster_region != null ? var.target_cluster_region : (var.source_cluster_region != null ? var.source_cluster_region : var.region)
  visibility       = var.provider_visibility
}

provider "kubernetes" {
  host                   = data.ibm_container_cluster_config.cluster_config.host
  client_certificate     = data.ibm_container_cluster_config.cluster_config.admin_certificate
  client_key             = data.ibm_container_cluster_config.cluster_config.admin_key
  cluster_ca_certificate = data.ibm_container_cluster_config.cluster_config.ca_certificate
}

provider "kubernetes" {
  alias                  = "target"
  host                   = (var.deployment_mode == "connected_component" || (var.deployment_mode == "full_backup_recovery" && var.recovery_type == "cross-cluster")) ? data.ibm_container_cluster_config.target_cluster_config[0].host : data.ibm_container_cluster_config.cluster_config.host
  client_certificate     = (var.deployment_mode == "connected_component" || (var.deployment_mode == "full_backup_recovery" && var.recovery_type == "cross-cluster")) ? data.ibm_container_cluster_config.target_cluster_config[0].admin_certificate : data.ibm_container_cluster_config.cluster_config.admin_certificate
  client_key             = (var.deployment_mode == "connected_component" || (var.deployment_mode == "full_backup_recovery" && var.recovery_type == "cross-cluster")) ? data.ibm_container_cluster_config.target_cluster_config[0].admin_key : data.ibm_container_cluster_config.cluster_config.admin_key
  cluster_ca_certificate = (var.deployment_mode == "connected_component" || (var.deployment_mode == "full_backup_recovery" && var.recovery_type == "cross-cluster")) ? data.ibm_container_cluster_config.target_cluster_config[0].ca_certificate : data.ibm_container_cluster_config.cluster_config.ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = data.ibm_container_cluster_config.cluster_config.host
    client_certificate     = data.ibm_container_cluster_config.cluster_config.admin_certificate
    client_key             = data.ibm_container_cluster_config.cluster_config.admin_key
    cluster_ca_certificate = data.ibm_container_cluster_config.cluster_config.ca_certificate
  }
}

provider "helm" {
  alias = "target"
  kubernetes = {
    host                   = (var.deployment_mode == "connected_component" || (var.deployment_mode == "full_backup_recovery" && var.recovery_type == "cross-cluster")) ? data.ibm_container_cluster_config.target_cluster_config[0].host : data.ibm_container_cluster_config.cluster_config.host
    client_certificate     = (var.deployment_mode == "connected_component" || (var.deployment_mode == "full_backup_recovery" && var.recovery_type == "cross-cluster")) ? data.ibm_container_cluster_config.target_cluster_config[0].admin_certificate : data.ibm_container_cluster_config.cluster_config.admin_certificate
    client_key             = (var.deployment_mode == "connected_component" || (var.deployment_mode == "full_backup_recovery" && var.recovery_type == "cross-cluster")) ? data.ibm_container_cluster_config.target_cluster_config[0].admin_key : data.ibm_container_cluster_config.cluster_config.admin_key
    cluster_ca_certificate = (var.deployment_mode == "connected_component" || (var.deployment_mode == "full_backup_recovery" && var.recovery_type == "cross-cluster")) ? data.ibm_container_cluster_config.target_cluster_config[0].ca_certificate : data.ibm_container_cluster_config.cluster_config.ca_certificate
  }
}
