provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = var.region
}

provider "kubernetes" {
  config_path = data.ibm_container_cluster_config.cluster_config.config_file_path
}

provider "helm" {
  kubernetes = {
    config_path = data.ibm_container_cluster_config.cluster_config.config_file_path
  }
}
