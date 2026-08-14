##############################################################################
# Provider configuration — VPE cross-cluster example (same IBM Cloud account)
#
# Both clusters live in the same account, so a single IBM Cloud API key is used.
# The root module requires an explicit ibm.source_account provider alias that points to
# the cluster account.  For same-account deployments ibm.source_account = ibm (same key).
#
# Two separate kubernetes/helm provider aliases are declared — one per cluster —
# so the root module invocations can deploy the DSC Helm chart to each cluster
# independently.
##############################################################################

# Default IBM provider — BRS instance, connections, and IAM resources
provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = var.region
}

##############################################################################
# Source cluster kubernetes + helm providers
##############################################################################

provider "kubernetes" {
  alias                  = "source"
  host                   = data.ibm_container_cluster_config.source_cluster_config.host
  client_certificate     = data.ibm_container_cluster_config.source_cluster_config.admin_certificate
  client_key             = data.ibm_container_cluster_config.source_cluster_config.admin_key
  cluster_ca_certificate = data.ibm_container_cluster_config.source_cluster_config.ca_certificate
}

provider "helm" {
  alias = "source"

  kubernetes = {
    host                   = data.ibm_container_cluster_config.source_cluster_config.host
    client_certificate     = data.ibm_container_cluster_config.source_cluster_config.admin_certificate
    client_key             = data.ibm_container_cluster_config.source_cluster_config.admin_key
    cluster_ca_certificate = data.ibm_container_cluster_config.source_cluster_config.ca_certificate
  }
}

##############################################################################
# Target cluster kubernetes + helm providers
##############################################################################

provider "kubernetes" {
  alias                  = "target"
  host                   = data.ibm_container_cluster_config.target_cluster_config.host
  client_certificate     = data.ibm_container_cluster_config.target_cluster_config.admin_certificate
  client_key             = data.ibm_container_cluster_config.target_cluster_config.admin_key
  cluster_ca_certificate = data.ibm_container_cluster_config.target_cluster_config.ca_certificate
}

provider "helm" {
  alias = "target"

  kubernetes = {
    host                   = data.ibm_container_cluster_config.target_cluster_config.host
    client_certificate     = data.ibm_container_cluster_config.target_cluster_config.admin_certificate
    client_key             = data.ibm_container_cluster_config.target_cluster_config.admin_key
    cluster_ca_certificate = data.ibm_container_cluster_config.target_cluster_config.ca_certificate
  }
}
