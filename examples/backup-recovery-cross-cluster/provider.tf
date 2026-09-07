##############################################################################
# Provider configuration — VPE cross-cluster example (same IBM Cloud account)
#
# Both clusters live in the same account, so a single IBM Cloud API key is used.
# The root module uses the default ibm provider for IBM Cloud resources.
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

  # burst_limit = 0 disables the client-side Kubernetes API rate limiter.
  # Without this, helm ≥ 3.x performs an OpenAPI schema download on every
  # install; on freshly-created clusters the API server can time out under
  # the concurrent load from two parallel providers.
  burst_limit = 0

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

  burst_limit = 0

  kubernetes = {
    host                   = data.ibm_container_cluster_config.target_cluster_config.host
    client_certificate     = data.ibm_container_cluster_config.target_cluster_config.admin_certificate
    client_key             = data.ibm_container_cluster_config.target_cluster_config.admin_key
    cluster_ca_certificate = data.ibm_container_cluster_config.target_cluster_config.ca_certificate
  }
}
