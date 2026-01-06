########################################################################################################################
# Provider config
########################################################################################################################

provider "ibm" {
  ibmcloud_api_key      = var.ibmcloud_api_key
  region                = var.region
  visibility            = var.provider_visibility
  private_endpoint_type = (var.provider_visibility == "private" && var.region == "ca-mon") ? "vpe" : null
}

# Kubernetes provider for ROKS cluster
provider "kubernetes" {
  host                   = data.ibm_container_cluster_config.cluster_config.host
  client_certificate     = data.ibm_container_cluster_config.cluster_config.admin_certificate
  client_key             = data.ibm_container_cluster_config.cluster_config.admin_key
  cluster_ca_certificate = data.ibm_container_cluster_config.cluster_config.ca_certificate
}

# Helm provider for ROKS cluster
provider "helm" {
  kubernetes = {
    host                   = data.ibm_container_cluster_config.cluster_config.host
    client_certificate     = data.ibm_container_cluster_config.cluster_config.admin_certificate
    client_key             = data.ibm_container_cluster_config.cluster_config.admin_key
    cluster_ca_certificate = data.ibm_container_cluster_config.cluster_config.ca_certificate
  }

  registries = [
    { url = "oci://icr.io", username = "iamapikey", password = var.ibmcloud_api_key }
  ]
}
