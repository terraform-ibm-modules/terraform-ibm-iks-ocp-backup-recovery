##############################################################################
# Resource Group
##############################################################################

module "resource_group" {
  source                       = "terraform-ibm-modules/resource-group/ibm"
  version                      = "1.6.0"
  resource_group_name          = var.resource_group == null ? "${var.prefix}-resource-group" : null
  existing_resource_group_name = var.resource_group
}

########################################################################################################################
# Private-only VPC + Subnet
#
# Deliberately NO ibm_is_public_gateway and NO public_gateway attached to the subnet, so workers have no route to the
# public internet. This mimics a locked-down customer environment. Everything the cluster and the Data Source Connector
# need must be reachable through private endpoints (ICR, IAM, COS, BRS via VPE gateway).
########################################################################################################################

resource "ibm_is_vpc" "vpc" {
  name                      = "${var.prefix}-vpc"
  resource_group            = module.resource_group.resource_group_id
  address_prefix_management = "auto"
  tags                      = var.resource_tags
}

resource "ibm_is_subnet" "subnet_zone_1" {
  name                     = "${var.prefix}-subnet-1"
  vpc                      = ibm_is_vpc.vpc.id
  resource_group           = module.resource_group.resource_group_id
  zone                     = "${var.region}-1"
  total_ipv4_address_count = 256
  # public_gateway intentionally omitted
}

########################################################################################################################
# Wait for IAM to propagate subnet visibility before creating the cluster.
########################################################################################################################

resource "time_sleep" "wait_for_subnet" {
  depends_on      = [ibm_is_subnet.subnet_zone_1]
  create_duration = "30s"
}

########################################################################################################################
# Private-only OCP Cluster
########################################################################################################################

locals {
  cluster_vpc_subnets = {
    default = [
      {
        id         = ibm_is_subnet.subnet_zone_1.id
        cidr_block = ibm_is_subnet.subnet_zone_1.ipv4_cidr_block
        zone       = ibm_is_subnet.subnet_zone_1.zone
      }
    ]
  }

  worker_pools = [
    {
      subnet_prefix    = "default"
      pool_name        = "default" # ibm_container_vpc_cluster automatically names default pool "default" (See https://github.com/IBM-Cloud/terraform-provider-ibm/issues/2849)
      machine_type     = "bx2.4x16"
      operating_system = "RHCOS"
      workers_per_zone = 2 # minimum of 2 is allowed when using single zone
    }
  ]

  brs_vpe_name = "${var.prefix}-brs-vpe"
}

module "ocp_base" {
  source            = "terraform-ibm-modules/base-ocp-vpc/ibm"
  version           = "3.87.1"
  resource_group_id = module.resource_group.resource_group_id
  region            = var.region
  tags              = var.resource_tags
  cluster_name      = "${var.prefix}-cluster"
  # Force-delete the PVCs so that destroy does not hang on the test workload volume.
  force_delete_storage = true
  vpc_id               = ibm_is_vpc.vpc.id
  vpc_subnets          = local.cluster_vpc_subnets
  ocp_version          = var.ocp_version
  worker_pools         = local.worker_pools
  access_tags          = var.access_tags
  ocp_entitlement      = var.ocp_entitlement

  # Private-only cluster: no public service endpoint.
  disable_public_endpoint = true
  # false (default) keeps outbound traffic protection ON, i.e. workers cannot reach the public internet.
  disable_outbound_traffic_protection = false

  addons = {
    vpc-block-csi-driver = {
      version = "5.2"
    }
  }
  depends_on = [time_sleep.wait_for_subnet]
}

data "ibm_container_cluster_config" "cluster_config" {
  cluster_name_id   = module.ocp_base.cluster_id
  resource_group_id = module.resource_group.resource_group_id
  admin             = true
  # The cluster has no public endpoint. The machine running Terraform must be able to reach the private endpoint
  # (VPN, Direct Link, or a host inside the VPC).
  endpoint_type = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
}

# Sleep to allow RBAC sync on cluster and wait for ocp_base (which manages the
# vpc-block-csi-driver addon) to fully complete before the backup module starts.
resource "time_sleep" "wait_operators" {
  depends_on = [
    data.ibm_container_cluster_config.cluster_config,
    module.ocp_base,
  ]
  create_duration = "60s"
}

########################################################################################################################
# BRS Instance (owned by this example)
########################################################################################################################

locals {
  # When an existing BRS CRN is provided, derive its region from field [5] of the CRN
  # (e.g. "crn:v1:bluemix:public:backup-recovery:au-syd:...") so the registry module's
  # region/CRN validation always passes regardless of what var.region is set to.
  brs_region = var.existing_brs_instance_crn != null && var.existing_brs_instance_crn != "" ? element(split(":", var.existing_brs_instance_crn), 5) : var.region
}

module "brs_instance" {
  source  = "terraform-ibm-modules/backup-recovery/ibm"
  version = "1.12.3"
  providers = {
    ibm = ibm
  }

  region                    = local.brs_region
  resource_group_id         = module.resource_group.resource_group_id
  ibmcloud_api_key          = var.ibmcloud_api_key
  instance_name             = "${var.prefix}-brs-instance"
  existing_brs_instance_crn = var.existing_brs_instance_crn != null && var.existing_brs_instance_crn != "" ? var.existing_brs_instance_crn : null
  create_new_instance       = var.existing_brs_instance_crn == null
  connection_name           = "${var.prefix}-brs-connection-RoksVpc"
  create_new_connection     = true
  resource_tags             = var.resource_tags
  access_tags               = var.access_tags
  endpoint_type             = var.brs_endpoint_type
  connection_env_type       = "kRoksVpc"
  policies = [
    {
      name              = "${var.prefix}-retention"
      create_new_policy = true
      schedule = {
        unit = "Days"
        day_schedule = {
          frequency = 1
        }
      }
      retention = {
        unit     = "Days"
        duration = 30
      }
    }
  ]
}

##############################################################################
# VPE Gateway — routes DSC <-> BRS over the IBM private backbone
#
# Created BEFORE the backup module (which installs the connector and registers
# the source). Without a public gateway the connector has no other path to BRS,
# so the gateway and its reserved IP must exist before the connector starts.
##############################################################################

data "ibm_is_security_group" "kube_vpeg_sg" {
  name = "kube-vpegw-${ibm_is_vpc.vpc.id}"

  depends_on = [module.ocp_base]
}

resource "ibm_is_subnet_reserved_ip" "brs_vpe" {
  subnet      = ibm_is_subnet.subnet_zone_1.id
  name        = "${local.brs_vpe_name}-${replace(ibm_is_subnet.subnet_zone_1.zone, "${var.region}-", "")}"
  auto_delete = false
}

resource "ibm_is_virtual_endpoint_gateway" "brs_vpe" {
  name            = local.brs_vpe_name
  vpc             = ibm_is_vpc.vpc.id
  resource_group  = module.resource_group.resource_group_id
  security_groups = [data.ibm_is_security_group.kube_vpeg_sg.id]

  target {
    crn           = module.brs_instance.brs_instance_crn
    resource_type = "provider_cloud_service"
  }

  depends_on = [ibm_is_subnet_reserved_ip.brs_vpe]
}

resource "ibm_is_virtual_endpoint_gateway_ip" "brs_vpe" {
  gateway     = ibm_is_virtual_endpoint_gateway.brs_vpe.id
  reserved_ip = ibm_is_subnet_reserved_ip.brs_vpe.reserved_ip
}

########################################################################################################################
# Backup & Recovery for ROKS with Data Source Connector
########################################################################################################################

module "backup_recover_protect_ocp" {
  source = "../.."
  providers = {
    ibm = ibm
  }

  # ---- Cluster ----
  cluster_id                   = module.ocp_base.cluster_id
  cluster_resource_group_id    = module.resource_group.resource_group_id
  cluster_config_endpoint_type = var.cluster_config_endpoint_type
  kube_type                    = "openshift"
  ibmcloud_api_key             = var.ibmcloud_api_key
  # enable_auto_protect is set to false to avoid issues when running terraform pipelines; in production set to true.
  enable_auto_protect = false
  # Disable automatic tag addition to prevent drift with the ocp_base module
  add_cluster_tags = false

  # ---- BRS prerequisite inputs (from module.brs_instance) ----
  connection_env_type      = "kRoksVpc"
  brs_endpoint_type        = var.brs_endpoint_type
  brs_tenant_id            = module.brs_instance.tenant_id
  brs_connection_id        = module.brs_instance.connection_id
  brs_registration_token   = module.brs_instance.registration_token
  brs_instance_guid        = module.brs_instance.brs_instance_guid
  brs_instance_crn         = module.brs_instance.brs_instance_crn
  brs_instance_public_url  = nonsensitive(module.brs_instance.brs_instance.extensions["endpoints.public"])
  brs_instance_private_url = nonsensitive(module.brs_instance.brs_instance.extensions["endpoints.private"])
  resolved_policy_ids      = module.brs_instance.resolved_policy_ids

  dsc_storage_class     = var.dsc_storage_class
  dsc_worker_pool_zones = 1

  datamover_service_type = var.datamover_service_type

  # ---- Backup Policy ----
  auto_protect_policy_name = "${var.prefix}-retention"

  # Protect the test workload namespace. Referencing the namespace resource (not
  # the literal string) ensures it exists before BRS source discovery resolves
  # the object name to an ID. policy_name must match a policy created by
  # module.brs_instance above.
  protection_groups = [
    {
      name        = "${var.prefix}-pg"
      description = "Backup test workloads"
      policy_name = "${var.prefix}-retention"
      priority    = "kHigh"

      enable_indexing       = true
      leverage_csi_snapshot = true
      non_snapshot_backup   = false
      volume_backup_failure = false

      objects = [
        {
          name                        = kubernetes_namespace_v1.brs_testing.metadata[0].name
          backup_only_pvc             = false
          fail_backup_on_hook_failure = false
        }
      ]
    }
  ]

  # The connector must not start until the VPE gateway and its reserved IP exist.
  depends_on = [
    time_sleep.wait_operators,
    ibm_is_virtual_endpoint_gateway_ip.brs_vpe,
  ]
}
