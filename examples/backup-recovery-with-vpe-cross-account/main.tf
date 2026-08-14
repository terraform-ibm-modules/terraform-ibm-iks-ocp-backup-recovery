##############################################################################
# backup-recovery-with-vpe-cross-account example
#
# Demonstrates BRS VPE connectivity across two IBM Cloud accounts:
#
#   SOURCE account  (source_ibmcloud_api_key / ibm.source provider alias)
#     - IKS VPC cluster  (created or existing)
#     - VPC + subnet + public gateway  (created when cluster_name_id = null)
#     - VPE Gateway  (ibm_is_virtual_endpoint_gateway.brs_vpe — source account)
#
#   TARGET account  (ibmcloud_api_key / default ibm provider)
#     - BRS instance  (new or existing)
#     - BRS data-source connection + registration token
#     - S2S IAM authorization policy  (module.brs_s2s_auth — target account)
#
# Apply order
# -----------
# Track A (target account, starts immediately):
#   BRS instance → connection → registration token
#   S2S IAM auth policy  (waits only for BRS instance GUID)
#
# Track B (source account, starts immediately in parallel with Track A):
#   VPC → subnet → gateway → IKS cluster
#
# Gate: S2S policy created → VPEG created (source account VPC)
# Gate: VPEG live + cluster kubeconfig ready → DSC Helm install
# → source registration → protection groups → (optional) backup + recovery
#
# After apply, exec into the DSC pod and run:
#   getent hosts <brs_private_hostname>
# The result should resolve to the VPEG reserved IP, confirming that
# DSC→BRS traffic routes through the IBM private backbone.
##############################################################################

locals {
  brs_region = var.brs_region != null ? var.brs_region : var.region

  # cluster_id: existing cluster name/ID or newly created cluster ID.
  cluster_id = var.cluster_name_id != null ? data.ibm_container_vpc_cluster.vpc_cluster_data[0].name : ibm_container_vpc_cluster.vpc_cluster[0].id

  # vpc_id / vpc_subnets: used by module.brs_vpe and data.ibm_is_security_group.kube_vpeg_sg.
  # For a NEW cluster (cluster_name_id = null) these come from the ibm_is_vpc /
  # ibm_is_subnet resources created earlier in this file — always known at plan time.
  # NOTE: the existing-cluster path (cluster_name_id != null) is not supported for
  # automated VPEG creation in this example because ibm_container_vpc_cluster does
  # not expose vpc_id as a top-level attribute; supply vpc_id / vpc_subnets explicitly
  # via variables if you need to bring your own cluster.
  vpc_id = ibm_is_vpc.vpc[0].id
  vpc_subnets = [
    {
      name = ibm_is_subnet.subnet_zone_1[0].name
      id   = ibm_is_subnet.subnet_zone_1[0].id
      zone = ibm_is_subnet.subnet_zone_1[0].zone
    }
  ]
}

##############################################################################
# Source account identity (used for cross-account S2S policy)
# The ibm_iam_auth_token data source only exposes raw JWT strings.
# Decode the payload (middle segment) to extract the BSS account ID.
##############################################################################

data "ibm_iam_auth_token" "source_account" {
  provider = ibm.source
}

locals {
  src_jwt_raw = split(".", data.ibm_iam_auth_token.source_account.iam_access_token)[1]
  src_jwt_padded = format("%s%s",
    local.src_jwt_raw,
    substr("====", 0, (4 - (length(local.src_jwt_raw) % 4)) % 4)
  )
  source_account_id = jsondecode(
    base64decode(replace(replace(local.src_jwt_padded, "-", "+"), "_", "/"))
  ).account.bss
}

##############################################################################
# Resource groups
##############################################################################

# Source-account resource group (cluster, VPC, VPEG).
module "source_resource_group" {
  source  = "terraform-ibm-modules/resource-group/ibm"
  version = "1.6.0"
  providers = {
    ibm = ibm.source
  }
  resource_group_name          = var.source_resource_group == null ? "${var.prefix}-source-rg" : null
  existing_resource_group_name = var.source_resource_group
}

# Target-account resource group (BRS instance).
module "target_resource_group" {
  source  = "terraform-ibm-modules/resource-group/ibm"
  version = "1.6.0"
  # uses default ibm provider (target account)
  resource_group_name          = var.target_resource_group == null ? "${var.prefix}-target-rg" : null
  existing_resource_group_name = var.target_resource_group
}

##############################################################################
# Source-account VPC + subnet + gateway  (created when cluster_name_id = null)
##############################################################################

resource "ibm_is_vpc" "vpc" {
  count    = var.cluster_name_id == null ? 1 : 0
  provider = ibm.source

  name                      = "${var.prefix}-vpc"
  resource_group            = module.source_resource_group.resource_group_id
  address_prefix_management = "auto"
  tags                      = var.resource_tags
}

resource "ibm_is_public_gateway" "gateway" {
  count    = var.cluster_name_id == null ? 1 : 0
  provider = ibm.source

  name           = "${var.prefix}-gateway-1"
  vpc            = ibm_is_vpc.vpc[0].id
  resource_group = module.source_resource_group.resource_group_id
  zone           = "${var.region}-1"
}

resource "ibm_is_subnet" "subnet_zone_1" {
  count    = var.cluster_name_id == null ? 1 : 0
  provider = ibm.source

  name                     = "${var.prefix}-subnet-1"
  vpc                      = ibm_is_vpc.vpc[0].id
  resource_group           = module.source_resource_group.resource_group_id
  zone                     = "${var.region}-1"
  total_ipv4_address_count = 256
  public_gateway           = ibm_is_public_gateway.gateway[0].id
}

##############################################################################
# Source-account IKS cluster  (created when cluster_name_id = null)
##############################################################################

resource "ibm_container_vpc_cluster" "vpc_cluster" {
  count    = var.cluster_name_id == null ? 1 : 0
  provider = ibm.source

  name                                = "${var.prefix}-cluster"
  vpc_id                              = ibm_is_vpc.vpc[0].id
  flavor                              = "bx2.4x16"
  force_delete_storage                = true
  resource_group_id                   = module.source_resource_group.resource_group_id
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
# Existing cluster lookup  (when cluster_name_id is provided)
##############################################################################

data "ibm_container_vpc_cluster" "vpc_cluster_data" {
  count    = var.cluster_name_id != null ? 1 : 0
  provider = ibm.source

  name              = var.cluster_name_id
  resource_group_id = module.source_resource_group.resource_group_id
}

##############################################################################
# Cluster kubeconfig  (source account, used by kubernetes + helm providers)
##############################################################################

data "ibm_container_cluster_config" "cluster_config" {
  provider = ibm.source

  cluster_name_id   = local.cluster_id
  resource_group_id = module.source_resource_group.resource_group_id
  admin             = true
  endpoint_type     = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
}

##############################################################################
# BRS backup & recovery module
#
# The default ibm provider (target account) handles all BRS resources:
#   - BRS instance, data-source connection, registration token
#
# The ibm.source_account provider alias (source account) handles all cluster
# and VPC resources:
#   - cluster data sources, DSC worker pool, Helm chart, source registration
#
# VPE Gateway and S2S policy are created directly in this example below the
# module call (see "S2S IAM Authorization Policy" and "VPE Gateway" sections).
##############################################################################

module "backup_recovery" {
  source = "../.."
  providers = {
    ibm                = ibm        # target account — BRS instance, connection
    ibm.source_account = ibm.source # source account — cluster, DSC worker pool
  }

  # ---- Cluster (source account) ----
  cluster_id                   = local.cluster_id
  cluster_resource_group_id    = module.source_resource_group.resource_group_id
  cluster_config_endpoint_type = var.cluster_config_endpoint_type
  kube_type                    = "kubernetes"
  connection_env_type          = "kIksVpc"
  ibmcloud_api_key             = var.ibmcloud_api_key
  region                       = local.brs_region
  dsc_storage_class            = "ibmc-vpc-block-metro-5iops-tier"
  dsc_worker_pool_zones        = 1
  add_dsc_rules_to_cluster_sg  = false
  enable_auto_protect          = false

  # ---- BRS instance (target account) ----
  brs_resource_group_id     = module.target_resource_group.resource_group_id
  existing_brs_instance_crn = var.existing_brs_instance_crn
  brs_instance_name         = "${var.prefix}-brs"
  brs_connection_name       = "${var.prefix}-brs-connection"
  brs_create_new_connection = true

  # Use public endpoint so Terraform (CI/workstation) can reach the BRS API.
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
      description = "Backs up the brs-testing-10g namespace (StatefulSet with 20Gi VPC Block PVC)"
      objects     = [{ name = "brs-testing-10g" }]
    }
  ]

  resource_tags = var.resource_tags
  access_tags   = var.access_tags
}

##############################################################################
# S2S IAM Authorization Policy (target/BRS account)
# Allows the source-account VPC endpoint-gateway service to resolve the BRS
# CRN across account boundaries. Created in the TARGET account (default ibm provider).
##############################################################################

module "brs_s2s_auth" {
  source  = "terraform-ibm-modules/s2s-auth/ibm"
  version = "2.3.1"

  enable_cbr = false

  service_map = {
    "brs-vpe-source-to-brs-target" = {
      source_service_name         = "is"
      source_resource_type        = "endpoint-gateway"
      source_service_account_id   = local.source_account_id
      target_service_name         = "backup-recovery"
      target_resource_instance_id = module.backup_recovery.brs_instance_guid
      roles                       = ["Viewer"]
      description                 = "Allow source-account VPC endpoint-gateway to target BRS instance ${module.backup_recovery.brs_instance_guid}"
    }
  }

  depends_on = [module.backup_recovery]
}

##############################################################################
# VPE Gateway (source account)
# Routes DSC↔BRS traffic over the IBM private backbone.
##############################################################################

locals {
  brs_vpe_name    = "${var.prefix}-brs-connection-vpe"
  brs_vpe_subnets = { for s in local.vpc_subnets : s.zone => s }
}

data "ibm_is_security_group" "kube_vpeg_sg" {
  provider = ibm.source
  name     = "kube-vpegw-${local.vpc_id}"
}

resource "ibm_is_subnet_reserved_ip" "brs_vpe_ip" {
  for_each = local.brs_vpe_subnets
  provider = ibm.source
  subnet   = each.value.id
  name     = "${local.brs_vpe_name}-${each.key}-ip"
}

resource "ibm_is_virtual_endpoint_gateway" "brs_vpe" {
  provider        = ibm.source
  name            = local.brs_vpe_name
  vpc             = local.vpc_id
  resource_group  = module.source_resource_group.resource_group_id
  security_groups = [data.ibm_is_security_group.kube_vpeg_sg.id]

  target {
    crn           = module.backup_recovery.brs_instance_crn
    resource_type = "provider_cloud_service"
  }

  depends_on = [module.brs_s2s_auth]
}

resource "ibm_is_virtual_endpoint_gateway_ip" "brs_vpe_ip" {
  for_each    = local.brs_vpe_subnets
  provider    = ibm.source
  gateway     = ibm_is_virtual_endpoint_gateway.brs_vpe.id
  reserved_ip = ibm_is_subnet_reserved_ip.brs_vpe_ip[each.key].reserved_ip
}
