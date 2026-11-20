terraform {
  required_version = ">= 1.9.0"

  required_providers {
    ibm = {
      source = "IBM-Cloud/ibm"
      # Pin to lowest supported provider version to test backwards compatibility
      version = "2.10.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.1, < 4.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.1.0, < 4.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12.1, < 1.0.0"
    }
  }
}
