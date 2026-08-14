##############################################################################
# backup-recovery-with-vpe example
#
# Demonstrates BRS VPE connectivity within a SINGLE IBM Cloud account:
#
#   - IKS VPC cluster  (created or existing)
#   - VPC + subnet + public gateway  (created when cluster_name_id = null)
#   - BRS instance  (new or existing)
#   - VPE Gateway in the cluster VPC → routes DSC↔BRS over IBM private backbone
#   - Protection group targeting var.workload_namespace
#
# For a cross-account variant (BRS in a different IBM Cloud account) see
# examples/backup-recovery-with-vpe-cross-account.
#
# Apply order (enforced by the root module's internal dependency graph):
#   VPC → subnet → cluster → VPEG → DSC Helm → source registration → PG
##############################################################################

locals {
  # cluster_id resolves to the newly-created cluster ID or the existing one.
  cluster_id = var.cluster_name_id != null ? data.ibm_container_vpc_cluster.vpc_cluster_data[0].name : ibm_container_vpc_cluster.vpc_cluster[0].id

  # VPC and subnet info for the VPE Gateway.
  # For a new cluster these are known at plan time from the ibm_is_* resources.
  # For an existing cluster (cluster_name_id != null) the caller must supply
  # var.vpc_id and var.vpc_subnets explicitly.
  vpc_id = var.cluster_name_id == null ? ibm_is_vpc.vpc[0].id : var.vpc_id
  vpc_subnets = var.cluster_name_id == null ? [
    {
      name = ibm_is_subnet.subnet_zone_1[0].name
      id   = ibm_is_subnet.subnet_zone_1[0].id
      zone = ibm_is_subnet.subnet_zone_1[0].zone
    }
  ] : var.vpc_subnets

  brs_vpe_name     = "${var.prefix}-brs-connection-vpe"
  brs_vpe_subnets  = { for s in local.vpc_subnets : s.zone => s }
  brs_instance_crn = module.backup_recovery.brs_instance_crn
}

##############################################################################
# Resource Group
##############################################################################

module "resource_group" {
  source                       = "terraform-ibm-modules/resource-group/ibm"
  version                      = "1.6.0"
  resource_group_name          = var.resource_group == null ? "${var.prefix}-resource-group" : null
  existing_resource_group_name = var.resource_group
}

##############################################################################
# VPC + Subnet + Public Gateway  (only when creating a new cluster)
##############################################################################

resource "ibm_is_vpc" "vpc" {
  count                     = var.cluster_name_id == null ? 1 : 0
  name                      = "${var.prefix}-vpc"
  resource_group            = module.resource_group.resource_group_id
  address_prefix_management = "auto"
  tags                      = var.resource_tags
}

resource "ibm_is_public_gateway" "gateway" {
  count          = var.cluster_name_id == null ? 1 : 0
  name           = "${var.prefix}-gateway-1"
  vpc            = ibm_is_vpc.vpc[0].id
  resource_group = module.resource_group.resource_group_id
  zone           = "${var.region}-1"
}

resource "ibm_is_subnet" "subnet_zone_1" {
  count                    = var.cluster_name_id == null ? 1 : 0
  name                     = "${var.prefix}-subnet-1"
  vpc                      = ibm_is_vpc.vpc[0].id
  resource_group           = module.resource_group.resource_group_id
  zone                     = "${var.region}-1"
  total_ipv4_address_count = 256
  public_gateway           = ibm_is_public_gateway.gateway[0].id
}

##############################################################################
# IKS VPC Cluster  (only when creating a new cluster)
##############################################################################

resource "ibm_container_vpc_cluster" "vpc_cluster" {
  count                               = var.cluster_name_id == null ? 1 : 0
  name                                = "${var.prefix}-cluster"
  vpc_id                              = ibm_is_vpc.vpc[0].id
  flavor                              = "bx2.4x16"
  force_delete_storage                = true
  resource_group_id                   = module.resource_group.resource_group_id
  worker_count                        = 2
  disable_outbound_traffic_protection = true
  tags                                = var.resource_tags
  zones {
    subnet_id = ibm_is_subnet.subnet_zone_1[0].id
    name      = "${var.region}-1"
  }
  lifecycle {
    ignore_changes = [tags]
  }
}

##############################################################################
# Existing cluster lookup  (only when cluster_name_id is provided)
##############################################################################

data "ibm_container_vpc_cluster" "vpc_cluster_data" {
  count             = var.cluster_name_id != null ? 1 : 0
  name              = var.cluster_name_id
  resource_group_id = module.resource_group.resource_group_id
}

##############################################################################
# Cluster kubeconfig
##############################################################################

data "ibm_container_cluster_config" "cluster_config" {
  cluster_name_id   = local.cluster_id
  resource_group_id = module.resource_group.resource_group_id
  admin             = true
  endpoint_type     = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
}

##############################################################################
# BRS Backup & Recovery with VPEG connectivity
##############################################################################

module "backup_recovery" {
  source = "../.."
  providers = {
    ibm                = ibm
    ibm.source_account = ibm
  }

  # ---- Cluster ----
  cluster_id                   = local.cluster_id
  cluster_resource_group_id    = module.resource_group.resource_group_id
  cluster_config_endpoint_type = var.cluster_config_endpoint_type
  kube_type                    = "kubernetes"
  connection_env_type          = "kIksVpc"
  ibmcloud_api_key             = var.ibmcloud_api_key
  region                       = var.region
  dsc_storage_class            = "ibmc-vpc-block-metro-5iops-tier"
  dsc_worker_pool_zones        = 1
  add_dsc_rules_to_cluster_sg  = false
  enable_auto_protect          = false

  # ---- BRS instance ----
  existing_brs_instance_crn = var.existing_brs_instance_crn
  brs_instance_name         = "${var.prefix}-brs"
  brs_connection_name       = "${var.prefix}-brs-connection"
  brs_create_new_connection = true

  # ---- Endpoint & VPEG connectivity ----
  # brs_endpoint_type = "public" lets Terraform (workstation/CI) reach the BRS API.
  # DSC traffic routes privately via the VPE Gateway created below.
  brs_endpoint_type = "public"

  # ---- Backup policy ----
  policies = [
    {
      name              = "${var.prefix}-retention"
      create_new_policy = true
      schedule = {
        unit         = "Days"
        day_schedule = { frequency = 1 }
      }
      retention = {
        unit     = "Days"
        duration = 30
      }
      use_default_backup_target = true
    }
  ]

  protection_groups = [
    {
      name        = "${var.prefix}-pg"
      policy_name = "${var.prefix}-retention"
      description = "Backs up the ${var.workload_namespace} namespace (StatefulSet with 20Gi VPC Block PVC)"
      objects     = [{ name = var.workload_namespace }]
    }
  ]

  resource_tags = var.resource_tags
  access_tags   = var.access_tags
}

##############################################################################
# VPE Gateway — routes DSC↔BRS over IBM private backbone
##############################################################################

data "ibm_is_security_group" "kube_vpeg_sg" {
  count = var.create_brs_vpe ? 1 : 0
  name  = "kube-vpegw-${local.vpc_id}"
}

resource "ibm_is_subnet_reserved_ip" "brs_vpe_ip" {
  for_each = var.create_brs_vpe ? local.brs_vpe_subnets : {}
  subnet   = each.value.id
  name     = "${local.brs_vpe_name}-${each.key}-ip"
}

resource "ibm_is_virtual_endpoint_gateway" "brs_vpe" {
  count           = var.create_brs_vpe ? 1 : 0
  name            = local.brs_vpe_name
  vpc             = local.vpc_id
  resource_group  = module.resource_group.resource_group_id
  security_groups = [data.ibm_is_security_group.kube_vpeg_sg[0].id]

  target {
    crn           = local.brs_instance_crn
    resource_type = "provider_cloud_service"
  }

  depends_on = [module.backup_recovery]
}

resource "ibm_is_virtual_endpoint_gateway_ip" "brs_vpe_ip" {
  for_each    = var.create_brs_vpe ? local.brs_vpe_subnets : {}
  gateway     = ibm_is_virtual_endpoint_gateway.brs_vpe[0].id
  reserved_ip = ibm_is_subnet_reserved_ip.brs_vpe_ip[each.key].reserved_ip
}
