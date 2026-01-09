#######################################################################################################################
# Resource Group
#######################################################################################################################
module "resource_group" {
  source                       = "terraform-ibm-modules/resource-group/ibm"
  version                      = "1.4.7"
  existing_resource_group_name = var.existing_resource_group_name
}

locals {
  prefix       = var.prefix != null ? trimspace(var.prefix) != "" ? "${var.prefix}-" : "" : ""
  cluster_name = "${local.prefix}${var.cluster_name}"
}

#############################################################################
# Provision VPC
#############################################################################

locals {
  subnets = {
    for count in range(1, 4) :
    "zone-${count}" => count == var.zone ? [
      {
        name           = "${var.prefix}-subnet-a"
        cidr           = var.address_prefix
        public_gateway = true
        acl_name       = "${var.prefix}-acl"
      }
    ] : []
  }

  public_gateway = {
    for count in range(1, 4) :
    "zone-${count}" => count == var.zone
  }
}

module "vpc" {
  source              = "terraform-ibm-modules/landing-zone-vpc/ibm"
  version             = "8.10.4"
  resource_group_id   = module.resource_group.resource_group_id
  region              = var.region
  name                = "vpc"
  prefix              = var.prefix
  tags                = var.vpc_resource_tags
  subnets             = local.subnets
  use_public_gateways = local.public_gateway
  network_acls = [{
    name                         = "${var.prefix}-acl"
    add_ibm_cloud_internal_rules = true
    add_vpc_connectivity_rules   = true
    prepend_ibm_rules            = true
    rules = [{
      name        = "inbound"
      action      = "allow"
      source      = "0.0.0.0/0"
      destination = "0.0.0.0/0"
      direction   = "inbound"
      },
      {
        name        = "outbound"
        action      = "allow"
        source      = "0.0.0.0/0"
        destination = "0.0.0.0/0"
        direction   = "outbound"
      }
    ]
    }
  ]
}

#############################################################################
# Provision Cluster
#############################################################################

locals {
  worker_pools = [
    {
      subnet_prefix    = "zone-${var.zone}"
      pool_name        = "default"
      machine_type     = var.machine_type
      workers_per_zone = var.workers_per_zone
      operating_system = var.operating_system
    }
  ]

  addons = merge({ for key, value in var.addons :
    key => value != null ? {
      version         = lookup(value, "version", null) == null && key == "openshift-data-foundation" ? "${var.openshift_version}.0" : lookup(value, "version", null)
      parameters_json = lookup(value, "parameters_json", null)
    } : null
    },
    # if the user overrides the values for the addons
    lookup(var.addons, "openshift-data-foundation", null) == null ? { openshift-data-foundation = {
      version         = "${var.openshift_version}.0"
      parameters_json = "{\"osdStorageClassName\":\"localblock\",\"odfDeploy\":\"true\",\"autoDiscoverDevices\":\"true\"}"
    } } : {},
    lookup(var.addons, "vpc-file-csi-driver", null) == null ? { vpc-file-csi-driver = {
      version = "2.0"
  } } : {})
}

module "ocp_base" {
  source                              = "terraform-ibm-modules/base-ocp-vpc/ibm"
  version                             = "3.76.3"
  resource_group_id                   = module.resource_group.resource_group_id
  region                              = var.region
  tags                                = var.cluster_resource_tags
  cluster_name                        = local.cluster_name
  force_delete_storage                = true
  vpc_id                              = module.vpc.vpc_id
  vpc_subnets                         = module.vpc.subnet_detail_map
  ocp_version                         = var.openshift_version
  worker_pools                        = local.worker_pools
  access_tags                         = var.access_tags
  ocp_entitlement                     = var.openshift_entitlement
  addons                              = local.addons
  cluster_ready_when                  = var.cluster_ready_when
  disable_outbound_traffic_protection = true # set as True to enable outbound traffic; required for accessing Operator Hub in the OpenShift console.
}

#######################################################################################################################
# Virtualization
#######################################################################################################################

# Retrieve information about an existing VPC cluster
data "ibm_container_cluster_config" "cluster_config" {
  cluster_name_id   = module.ocp_base.cluster_id
  resource_group_id = module.ocp_base.resource_group_id
  config_dir        = "${path.module}/kubeconfig"
  endpoint_type     = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
}

########################################################################################################################
# Backup & Recovery Service (BRS)
########################################################################################################################

module "backup_recovery_instance" {
  source                = "terraform-ibm-modules/backup-recovery/ibm"
  version               = "v1.1.10"
  region                = var.region
  resource_group_id     = module.resource_group.resource_group_id
  ibmcloud_api_key      = var.ibmcloud_api_key
  tags                  = var.resource_tags
  instance_name         = var.brs_instance_name != null ? var.brs_instance_name : "${var.prefix}-brs-instance"
  connection_name       = var.brs_connection_name != null ? var.brs_connection_name : "${var.prefix}-brs-connection"
  create_new_connection = true
  create_new_instance   = true
}


########################################################################################################################
# Backup & Recovery for IKS/ROKS with Data Source Connector
########################################################################################################################


module "protect_cluster" {
  source                       = "../.."
  cluster_id                   = module.ocp_base.cluster_id
  cluster_resource_group_id    = module.resource_group.resource_group_id
  cluster_config_endpoint_type = "private"
  add_dsc_rules_to_cluster_sg  = false
  dsc_registration_token       = module.backup_recovery_instance.registration_token
  kube_type                    = "openshift"
  connection_id                = module.backup_recovery_instance.connection_id
  ibmcloud_api_key             = var.ibmcloud_api_key
  # --- B&R Instance ---
  brs_instance_guid   = module.backup_recovery_instance.brs_instance_guid
  brs_instance_region = var.region
  brs_endpoint_type   = "public"
  brs_tenant_id       = module.backup_recovery_instance.tenant_id
  registration_name   = module.ocp_base.cluster_name
  # --- Backup Policy ---
  policy            = var.policy
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}
