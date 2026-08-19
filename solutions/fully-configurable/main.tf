locals {
  # --- Environment type detection ---
  is_vpc     = length(regexall("Vpc$", var.connection_env_type)) > 0
  is_classic = length(regexall("Classic$", var.connection_env_type)) > 0

  # --- Recovery mode detection ---
  is_full_recovery = var.deployment_mode == "full_backup_recovery"
}
# Retrieve information about an existing VPC cluster
# Uses ibm.source_cluster provider — source account in cross-account deployments.
data "ibm_container_vpc_cluster" "vpc_cluster" {
  count             = local.is_vpc ? 1 : 0
  provider          = ibm.source_cluster
  name              = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}

# Retrieve information about an existing Classic cluster
data "ibm_container_cluster" "classic_cluster" {
  count             = local.is_classic ? 1 : 0
  provider          = ibm.source_cluster
  name              = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}
data "ibm_container_cluster_config" "cluster_config" {
  provider          = ibm.source_cluster
  cluster_name_id   = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  config_dir        = "${path.module}/kubeconfig"
  endpoint_type     = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
  admin             = true

  # Wait for cluster to be ready before fetching config
  # This prevents timeouts when cluster is still provisioning
  depends_on = [
    data.ibm_container_vpc_cluster.vpc_cluster,
    data.ibm_container_cluster.classic_cluster
  ]
}

module "existing_brs_crn_parser" {
  count   = var.existing_brs_instance_crn != null ? 1 : 0
  source  = "terraform-ibm-modules/common-utilities/ibm//modules/crn-parser"
  version = "1.5.0"
  crn     = var.existing_brs_instance_crn
}

locals {
  region = var.existing_brs_instance_crn != null ? module.existing_brs_crn_parser[0].region : var.region
}

##############################################################################
# BRS Instance — owned by the DA, not the root module.
#
# The DA creates the BRS instance here (using the ibm / BRS-account provider)
# and passes the resulting values into module.protect_cluster as prerequisites.
# The root module's internal backup_recovery_instance is skipped when these
# values are provided (brs_tenant_id != null).
##############################################################################

module "brs_instance" {
  source                    = "terraform-ibm-modules/backup-recovery/ibm"
  version                   = "1.12.3"
  providers                 = { ibm = ibm } # always the BRS (target) account
  region                    = local.region
  resource_group_id         = var.brs_resource_group_id != null ? var.brs_resource_group_id : var.cluster_resource_group_id
  ibmcloud_api_key          = var.ibmcloud_api_key
  instance_name             = var.brs_instance_name
  service_type              = var.brs_service_type
  existing_brs_instance_crn = var.existing_brs_instance_crn != null && var.existing_brs_instance_crn != "" ? var.existing_brs_instance_crn : null
  create_new_instance       = var.create_new_brs_instance
  connection_name           = var.brs_connection_name
  create_new_connection     = var.brs_create_new_connection
  resource_tags             = var.resource_tags
  access_tags               = var.access_tags
  endpoint_type             = var.brs_endpoint_type
  connection_env_type       = var.connection_env_type
  policies                  = var.policies
}

# Stage 1: Source Cluster Infrastructure & DSC Helm Deployment (Source Account)
module "source_cluster_prep" {
  source = "../.."
  providers = {
    ibm        = ibm.source_cluster
    kubernetes = kubernetes
    helm       = helm
  }

  execution_stage              = "cluster_prep"
  cluster_id                   = var.cluster_id
  cluster_resource_group_id    = var.cluster_resource_group_id
  cluster_config_endpoint_type = var.cluster_config_endpoint_type
  add_dsc_rules_to_cluster_sg  = var.add_dsc_rules_to_cluster_sg
  kube_type                    = var.kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  connection_env_type          = var.connection_env_type
  ibmcloud_api_key             = var.source_ibmcloud_api_key != null ? var.source_ibmcloud_api_key : var.ibmcloud_api_key

  # DSC configuration for source cluster
  dsc_chart_uri           = var.dsc_chart_uri
  dsc_name                = var.dsc_name
  dsc_replicas            = var.dsc_replicas
  dsc_namespace           = var.dsc_namespace
  dsc_helm_timeout        = var.dsc_helm_timeout
  dsc_storage_class       = var.dsc_storage_class
  create_dsc_worker_pool  = var.create_dsc_worker_pool
  dsc_worker_pool_zones   = var.dsc_worker_pool_zones
  dsc_worker_pool_flavor  = var.dsc_worker_pool_flavor
  dsc_pod_cpu_limits      = var.dsc_pod_cpu_limits
  dsc_pod_memory_limits   = var.dsc_pod_memory_limits
  dsc_pod_cpu_requests    = var.dsc_pod_cpu_requests
  dsc_pod_memory_requests = var.dsc_pod_memory_requests

  # Auth token passed from BRS connection so DSC Helm deployment can register
  brs_registration_token = module.brs_instance.registration_token
}

# Stage 2: Source Cluster BRS Registration, Protection Groups & Operations (BRS Account)
module "protect_cluster" {
  source = "../.."
  providers = {
    ibm = ibm # target (BRS) account
  }

  execution_stage              = "brs_management"
  cluster_id                   = var.cluster_id
  cluster_resource_group_id    = var.cluster_resource_group_id
  cluster_config_endpoint_type = var.cluster_config_endpoint_type
  add_cluster_tags             = var.add_cluster_tags
  kube_type                    = var.kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  connection_env_type          = var.connection_env_type
  deployment_mode              = var.deployment_mode

  # BRS prerequisite inputs (DA owns the BRS instance via module.brs_instance)
  ibmcloud_api_key         = var.ibmcloud_api_key
  brs_endpoint_type        = var.brs_endpoint_type
  brs_tenant_id            = module.brs_instance.tenant_id
  brs_connection_id        = module.brs_instance.connection_id
  brs_registration_token   = module.brs_instance.registration_token
  brs_instance_guid        = module.brs_instance.brs_instance_guid
  brs_instance_crn         = module.brs_instance.brs_instance_crn
  brs_instance_public_url  = nonsensitive(module.brs_instance.brs_instance.extensions["endpoints.public"])
  brs_instance_private_url = nonsensitive(module.brs_instance.brs_instance.extensions["endpoints.private"])
  resolved_policy_ids      = module.brs_instance.resolved_policy_ids

  # brsagent SA token created by module.source_cluster_prep (cluster_prep stage).
  # The brs_management stage has count=0 for kubernetes_secret_v1.brsagent_token,
  # so the token must be passed in explicitly from the cluster_prep output.
  brsagent_token = module.source_cluster_prep.brsagent_token

  # DSC Settings referenced during registration/discovery
  dsc_chart_uri       = var.dsc_chart_uri
  dsc_name            = var.dsc_name
  dsc_namespace       = var.dsc_namespace
  registration_images = var.registration_images
  enable_auto_protect = var.enable_auto_protect

  # Backup Policy & Groups
  auto_protect_policy_name = var.auto_protect_policy_name
  protection_groups        = var.protection_groups

  # Recovery Settings
  recovery_mode                    = var.recovery_type
  target_cluster_id                = var.target_cluster_id
  target_cluster_resource_group_id = var.target_cluster_resource_group_id

  depends_on = [
    module.source_cluster_prep
  ]
}

##############################################################################
# Virtual Private Endpoint Gateway for BRS
##############################################################################

locals {
  # Cross-account detection: S2S policy needed only when the VPC account
  # (ibm.source_cluster) differs from the BRS instance account (ibm).
  tgt_jwt_raw = split(".", data.ibm_iam_auth_token.brs_account.iam_access_token)[1]
  tgt_jwt_padded = format("%s%s",
    local.tgt_jwt_raw,
    substr("====", 0, (4 - (length(local.tgt_jwt_raw) % 4)) % 4)
  )
  brs_account_id = jsondecode(
    base64decode(replace(replace(local.tgt_jwt_padded, "-", "+"), "_", "/"))
  ).account.bss

  src_jwt_raw = split(".", data.ibm_iam_auth_token.cluster_account.iam_access_token)[1]
  src_jwt_padded = format("%s%s",
    local.src_jwt_raw,
    substr("====", 0, (4 - (length(local.src_jwt_raw) % 4)) % 4)
  )
  cluster_account_id = jsondecode(
    base64decode(replace(replace(local.src_jwt_padded, "-", "+"), "_", "/"))
  ).account.bss

  is_cross_account = local.cluster_account_id != local.brs_account_id

  brs_vpe_active = var.create_source_cluster_brs_vpe_gateway && local.is_vpc

  brs_vpe_name_resolved = var.brs_vpe_name != null ? var.brs_vpe_name : "${lower(var.brs_connection_name)}-vpe"

  # Subnet auto-discovery from existing cluster worker pools.
  # When vpc_subnets is supplied explicitly (e.g. new cluster created in the same apply)
  # the lookup is skipped so the count is always plan-time-static.
  cluster_subnet_ids = local.brs_vpe_active && local.is_vpc && length(var.vpc_subnets) == 0 ? distinct(flatten(
    data.ibm_container_vpc_cluster.vpc_cluster[*].worker_pools[*].zones[*].subnets[*].id
  )) : []
  cluster_subnet_lookup_count = length(local.cluster_subnet_ids) > 0 ? length(local.cluster_subnet_ids) : 0

  resolved_vpc_id = var.vpc_id != null ? var.vpc_id : (
    local.cluster_subnet_lookup_count > 0 ? data.ibm_is_subnet.cluster_subnet[0].vpc : null
  )
  resolved_vpc_subnets = length(var.vpc_subnets) > 0 ? var.vpc_subnets : [
    for s in data.ibm_is_subnet.cluster_subnet : { name = s.name, id = s.id, zone = s.zone }
  ]
  brs_vpe_subnets_map = { for s in local.resolved_vpc_subnets : s.zone => s }
}

# IAM tokens used for cross-account detection.
data "ibm_iam_auth_token" "brs_account" {}
data "ibm_iam_auth_token" "cluster_account" {
  provider = ibm.source_cluster
}

# Subnet lookups for VPE auto-discovery (skipped when vpc_subnets supplied).
data "ibm_is_subnet" "cluster_subnet" {
  count      = local.cluster_subnet_lookup_count
  provider   = ibm.source_cluster
  identifier = local.cluster_subnet_ids[count.index]
}

# kube-vpegw security group — created automatically by IKS/ROKS for every VPC cluster.
data "ibm_is_security_group" "kube_vpeg_sg" {
  count    = local.brs_vpe_active ? 1 : 0
  provider = ibm.source_cluster
  name     = "kube-vpegw-${local.resolved_vpc_id}"

  depends_on = [
    data.ibm_container_vpc_cluster.vpc_cluster,
  ]
}

##############################################################################
# S2S IAM Authorization Policy  (cross-account only)
# Created in the BRS (target) account so the source-account VPC endpoint-gateway
# service can resolve the BRS CRN across account boundaries.
##############################################################################

module "brs_s2s_auth" {
  count   = local.brs_vpe_active && local.is_cross_account ? 1 : 0
  source  = "terraform-ibm-modules/s2s-auth/ibm"
  version = "2.3.1"

  enable_cbr = false

  service_map = {
    "brs-vpe-source-to-brs-target" = {
      source_service_name         = "is"
      source_resource_type        = "endpoint-gateway"
      source_service_account_id   = local.cluster_account_id
      target_service_name         = "backup-recovery"
      target_resource_instance_id = module.protect_cluster.brs_instance_guid
      roles                       = ["Viewer"]
      description                 = "Allow VPC endpoint-gateway in account ${local.cluster_account_id} to target BRS instance ${module.protect_cluster.brs_instance_guid}"
    }
  }

  depends_on = [module.protect_cluster]
}

# Reserved IPs — one per subnet.
resource "ibm_is_subnet_reserved_ip" "brs_vpe_ip" {
  for_each = local.brs_vpe_active ? local.brs_vpe_subnets_map : {}
  provider = ibm.source_cluster
  subnet   = each.value.id
  name     = "${local.brs_vpe_name_resolved}-${each.key}-ip"
}

# VPE Gateway — routes DSC↔BRS traffic over IBM private backbone.
# IBM Cloud enforces one VPE per (service, VPC) pair — a second workspace
# attempting to create a gateway for the same BRS instance in the same VPC
# would fail. The gateway is therefore always treated as shared infrastructure
# and is never destroyed when the workspace is torn down.
resource "ibm_is_virtual_endpoint_gateway" "brs_vpe" {
  count           = local.brs_vpe_active ? 1 : 0
  provider        = ibm.source_cluster
  name            = local.brs_vpe_name_resolved
  vpc             = local.resolved_vpc_id
  resource_group  = var.cluster_resource_group_id
  security_groups = [data.ibm_is_security_group.kube_vpeg_sg[0].id]

  target {
    crn           = module.protect_cluster.brs_instance_crn
    resource_type = "provider_cloud_service"
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [module.brs_s2s_auth]
}

resource "ibm_is_virtual_endpoint_gateway_ip" "brs_vpe_ip" {
  for_each    = local.brs_vpe_active ? local.brs_vpe_subnets_map : {}
  provider    = ibm.source_cluster
  gateway     = ibm_is_virtual_endpoint_gateway.brs_vpe[0].id
  reserved_ip = ibm_is_subnet_reserved_ip.brs_vpe_ip[each.key].reserved_ip

  lifecycle {
    prevent_destroy = true
  }
}

##############################################################################
# Recovery Configuration (Optional)
##############################################################################

locals {
  # Determine which explicitly Terraform-managed protection group to use for
  # recovery lookup. Only meaningful when protection_groups are defined —
  # auto-protect PGs are BRS-named (e.g. "AutoProtectK8s-060826-0707") and have
  # no relation to auto_protect_policy_name. For auto-protect, the real PG ID
  # comes from the auto_protect_pg_id output directly; recovery_pg_name is only
  # used to look up the protection_group_ids map and to build a label string.
  recovery_pg_name = local.is_full_recovery ? (
    var.recovery_protection_group_name != null ? var.recovery_protection_group_name :
    try(length(var.protection_groups), 0) > 0 ? var.protection_groups[0].name :
    null # auto-protect: no Terraform-managed PG name — pg_id comes from auto_protect_pg_id output
  ) : null

  # Human-readable label used in recovery resource names. Falls back to
  # "auto-protect" so the name is meaningful rather than using the policy name
  # (which has no relation to the BRS-assigned PG name).
  recovery_pg_label = local.recovery_pg_name != null ? local.recovery_pg_name : "auto-protect"

  # Resolved protection-group ID used in all recovery resources (wait, same-cluster,
  # cross-cluster). Prefers the explicitly Terraform-managed PG when recovery_pg_name
  # is set, falls back to the BRS-assigned auto-protect PG ID, then "" as a
  # plan-time placeholder (replaced by the real value at apply).
  # try() wraps coalesce() so that when all arguments are null (e.g. during a
  # plan before the module outputs are known) it gracefully returns "" instead
  # of throwing "no non-null, non-empty-string arguments".
  recovery_pg_id = try(coalesce(
    local.recovery_pg_name != null ? try(module.protect_cluster.protection_group_ids[local.recovery_pg_name], null) : null,
    module.protect_cluster.auto_protect_pg_id,
  ), "")
}

##############################################################################
# Target Cluster Registration
##############################################################################

# Needed for:
# 1. connected_component mode - to register both source and target clusters
# 2. full_backup_recovery mode with cross-cluster recovery
locals {
  deploy_target_cluster = (
    var.deployment_mode == "connected_component" ||
    (local.is_full_recovery && var.recovery_type == "cross-cluster")
  )
}

data "ibm_container_vpc_cluster" "target_cluster" {
  count             = local.deploy_target_cluster ? 1 : 0
  provider          = ibm.target_cluster
  name              = var.target_cluster_id
  resource_group_id = var.target_cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}

locals {
  # True region of the target cluster, taken from its CRN rather than from
  # var.source_cluster_region — the provider region is a caller input and can disagree
  # with where the cluster actually lives, which is precisely the failure this
  # guards against. CRN segment 5 is the region.
  target_cluster_region = local.deploy_target_cluster ? split(":", data.ibm_container_vpc_cluster.target_cluster[0].crn)[5] : null

  # A VPE is only ever built for a VPC target — the target module gates
  # module.brs_vpe on (create_target_cluster_brs_vpe_gateway && is_vpc). Mirroring
  # that here keeps the region precondition from rejecting a config where
  # create_target_cluster_brs_vpe_gateway is true but the target is Classic, in
  # which case no VPE exists and the region relationship is irrelevant.
  target_is_vpc = length(regexall("Vpc$", coalesce(var.target_connection_env_type, var.connection_env_type))) > 0
}

data "ibm_container_cluster_config" "target_cluster_config" {
  depends_on = [data.ibm_container_vpc_cluster.target_cluster]

  count             = local.deploy_target_cluster ? 1 : 0
  provider          = ibm.target_cluster
  cluster_name_id   = var.target_cluster_id
  resource_group_id = var.target_cluster_resource_group_id
  config_dir        = "${path.module}/kubeconfig"
  endpoint_type     = var.target_cluster_config_endpoint_type == "default" ? null : var.target_cluster_config_endpoint_type
  admin             = true

  # Fail at plan time when a VPE is requested for a target cluster whose region
  # does not match the BRS instance's region.
  #
  # VPE gateways are regional: one built in a us-east VPC cannot front a us-south
  # service endpoint. The VPC API accepts a cross-region gateway and reports it
  # "stable", but the DSC simply never connects — ibm_backup_recovery_source_registration
  # blocks for ~20 minutes before failing with "context deadline exceeded".
  #
  # To deploy the target cluster in a different region from BRS, set `target_cluster_region`
  # to match `region` (co-locate BRS with the target), or set `region` to match the target
  # cluster's region, or set `create_target_cluster_brs_vpe_gateway = false` if you provide
  # private connectivity by other means.
  #
  # This lives on an existing data source rather than a dedicated resource on purpose:
  # adding a new resource to module.target_cluster_registration's depends_on would defer
  # that module's data sources to apply time, making local.cluster_subnet_ids unknown and
  # breaking the count on data.ibm_is_subnet.cluster_subnet.
  lifecycle {
    precondition {
      condition     = !(var.create_target_cluster_brs_vpe_gateway && local.target_is_vpc) || local.target_cluster_region == local.region
      error_message = "Target cluster region '${local.target_cluster_region}' does not match the BRS instance region '${local.region}', but create_target_cluster_brs_vpe_gateway = true. A VPE gateway is regional and cannot route to a BRS instance in a different region. Fix by: (1) setting `target_cluster_region` to '${local.region}' so the target cluster's VPC is in the same region as BRS, (2) setting `region` to '${local.target_cluster_region}' to co-locate BRS with the target cluster, or (3) setting create_target_cluster_brs_vpe_gateway = false if you provide private connectivity by other means."
    }
  }
}

# Target cluster BRS connection — reuses the same BRS instance, creates a
# separate data-source connection for the target cluster.
module "brs_target_connection" {
  count   = local.deploy_target_cluster ? 1 : 0
  source  = "terraform-ibm-modules/backup-recovery/ibm"
  version = "1.12.3"
  providers = {
    ibm = ibm # target (BRS) account
  }

  region                    = local.region
  resource_group_id         = var.brs_resource_group_id != null ? var.brs_resource_group_id : var.cluster_resource_group_id
  ibmcloud_api_key          = var.ibmcloud_api_key
  instance_name             = var.brs_instance_name
  existing_brs_instance_crn = module.brs_instance.brs_instance_crn
  create_new_instance       = false
  connection_name           = var.target_brs_connection_name != null ? var.target_brs_connection_name : "${var.target_cluster_id}-target-connection"
  create_new_connection     = var.target_brs_create_new_connection
  resource_tags             = var.resource_tags
  access_tags               = var.access_tags
  endpoint_type             = var.brs_endpoint_type
  connection_env_type       = var.target_connection_env_type != null ? var.target_connection_env_type : var.connection_env_type
  policies                  = []
}

# Stage 1 (Target): Target Cluster Infrastructure & DSC Helm Deployment (Target Account)
module "target_cluster_prep" {
  count  = local.deploy_target_cluster ? 1 : 0
  source = "../.."

  providers = {
    ibm        = ibm.target_cluster
    helm       = helm.target
    kubernetes = kubernetes.target
  }

  execution_stage              = "cluster_prep"
  cluster_id                   = var.target_cluster_id
  cluster_resource_group_id    = var.target_cluster_resource_group_id
  cluster_config_endpoint_type = var.target_cluster_config_endpoint_type
  add_dsc_rules_to_cluster_sg  = var.add_dsc_rules_to_cluster_sg
  kube_type                    = var.target_kube_type != null ? var.target_kube_type : var.kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  connection_env_type          = var.target_connection_env_type != null ? var.target_connection_env_type : var.connection_env_type
  ibmcloud_api_key             = var.target_ibmcloud_api_key != null ? var.target_ibmcloud_api_key : (var.source_ibmcloud_api_key != null ? var.source_ibmcloud_api_key : var.ibmcloud_api_key)

  # DSC configuration for target
  dsc_chart_uri          = var.dsc_chart_uri
  dsc_name               = var.dsc_name
  dsc_replicas           = var.dsc_replicas
  dsc_namespace          = var.dsc_namespace
  dsc_helm_timeout       = var.dsc_helm_timeout
  dsc_storage_class      = var.target_dsc_storage_class
  create_dsc_worker_pool = var.target_create_dsc_worker_pool

  # Auth token passed from target BRS connection
  brs_registration_token = module.brs_target_connection[0].registration_token

  depends_on = [
    data.ibm_container_cluster_config.target_cluster_config
  ]
}

# Stage 2 (Target): Register target cluster with BRS (BRS Account)
module "target_cluster_registration" {
  count  = local.deploy_target_cluster ? 1 : 0
  source = "../.."

  providers = {
    ibm = ibm # BRS account
  }

  execution_stage              = "brs_management"
  cluster_id                   = var.target_cluster_id
  cluster_resource_group_id    = var.target_cluster_resource_group_id
  cluster_config_endpoint_type = var.target_cluster_config_endpoint_type
  kube_type                    = var.target_kube_type != null ? var.target_kube_type : var.kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  ibmcloud_api_key             = var.ibmcloud_api_key

  # BRS prerequisite inputs — same instance as source, target's own connection
  brs_endpoint_type        = var.brs_endpoint_type
  connection_env_type      = var.target_connection_env_type != null ? var.target_connection_env_type : var.connection_env_type
  brs_tenant_id            = module.brs_target_connection[0].tenant_id
  brs_connection_id        = module.brs_target_connection[0].connection_id
  brs_registration_token   = module.brs_target_connection[0].registration_token
  brs_instance_guid        = module.brs_instance.brs_instance_guid
  brs_instance_crn         = module.brs_instance.brs_instance_crn
  brs_instance_public_url  = nonsensitive(module.brs_instance.brs_instance.extensions["endpoints.public"])
  brs_instance_private_url = nonsensitive(module.brs_instance.brs_instance.extensions["endpoints.private"])
  resolved_policy_ids      = null

  # brsagent SA token created by module.target_cluster_prep (cluster_prep stage).
  # The brs_management stage has count=0 for kubernetes_secret_v1.brsagent_token,
  # so the token must be passed in explicitly from the cluster_prep output.
  brsagent_token = module.target_cluster_prep[0].brsagent_token

  # DSC settings referenced during registration
  dsc_chart_uri       = var.dsc_chart_uri
  dsc_name            = var.dsc_name
  dsc_namespace       = var.dsc_namespace
  registration_images = var.registration_images
  enable_auto_protect = false # Don't auto-protect target cluster

  # No protection groups for target (it's just a recovery destination)
  protection_groups = null

  depends_on = [
    module.target_cluster_prep
  ]
}

# VPE Gateway for target cluster (when create_target_cluster_brs_vpe_gateway = true)
# Routes target cluster's DSC↔BRS traffic over the IBM private backbone.
# Created here in the DA because the root module no longer manages VPE.
##############################################################################

locals {
  target_brs_vpe_active = var.create_target_cluster_brs_vpe_gateway && local.is_vpc && local.deploy_target_cluster

  target_brs_vpe_name_resolved = var.target_brs_vpe_name != null ? var.target_brs_vpe_name : "${lower(var.target_brs_connection_name != null ? var.target_brs_connection_name : "${var.target_cluster_id}-target-connection")}-vpe"

  # Subnet auto-discovery for target cluster (same pattern as source).
  target_cluster_subnet_ids = local.target_brs_vpe_active && length(var.target_vpc_subnets) == 0 ? distinct(flatten(
    data.ibm_container_vpc_cluster.target_cluster[*].worker_pools[*].zones[*].subnets[*].id
  )) : []
  target_cluster_subnet_lookup_count = length(local.target_cluster_subnet_ids)

  target_resolved_vpc_id = var.target_vpc_id != null ? var.target_vpc_id : (
    local.target_cluster_subnet_lookup_count > 0 ? data.ibm_is_subnet.target_cluster_subnet[0].vpc : null
  )
  target_resolved_vpc_subnets = length(var.target_vpc_subnets) > 0 ? var.target_vpc_subnets : [
    for s in data.ibm_is_subnet.target_cluster_subnet : { name = s.name, id = s.id, zone = s.zone }
  ]
  target_brs_vpe_subnets_map = { for s in local.target_resolved_vpc_subnets : s.zone => s }
}

data "ibm_is_subnet" "target_cluster_subnet" {
  count      = local.target_cluster_subnet_lookup_count
  provider   = ibm.target_cluster
  identifier = local.target_cluster_subnet_ids[count.index]
}

data "ibm_is_security_group" "target_kube_vpeg_sg" {
  count    = local.target_brs_vpe_active ? 1 : 0
  provider = ibm.target_cluster
  name     = "kube-vpegw-${local.target_resolved_vpc_id}"
}

resource "ibm_is_subnet_reserved_ip" "target_brs_vpe_ip" {
  for_each = local.target_brs_vpe_active ? local.target_brs_vpe_subnets_map : {}
  provider = ibm.target_cluster
  subnet   = each.value.id
  name     = "${local.target_brs_vpe_name_resolved}-${each.key}-ip"
}

resource "ibm_is_virtual_endpoint_gateway" "target_brs_vpe" {
  count           = local.target_brs_vpe_active ? 1 : 0
  provider        = ibm.target_cluster
  name            = local.target_brs_vpe_name_resolved
  vpc             = local.target_resolved_vpc_id
  resource_group  = var.target_cluster_resource_group_id
  security_groups = [data.ibm_is_security_group.target_kube_vpeg_sg[0].id]

  target {
    crn           = module.protect_cluster.brs_instance_crn
    resource_type = "provider_cloud_service"
  }

  depends_on = [module.target_cluster_registration]
}

resource "ibm_is_virtual_endpoint_gateway_ip" "target_brs_vpe_ip" {
  for_each    = local.target_brs_vpe_active ? local.target_brs_vpe_subnets_map : {}
  provider    = ibm.target_cluster
  gateway     = ibm_is_virtual_endpoint_gateway.target_brs_vpe[0].id
  reserved_ip = ibm_is_subnet_reserved_ip.target_brs_vpe_ip[each.key].reserved_ip
}

##############################################################################
# Recovery Storage Class Aliases (target cluster)
##############################################################################

# Velero restores each PVC with the storageClassName it had on the SOURCE
# cluster. In a Classic -> VPC migration those names (e.g. "ibmc-block-silver")
# do not and cannot exist on the VPC target, which only has ibmc-vpc-block-*
# classes. The restored PVC therefore stays Pending, the temporary data-mover
# pod cannot schedule ("unbound immediate PersistentVolumeClaims"), and BRS
# fails the recovery with "Timed out while waiting for temporary pod to start."
#
# The BRS recovery API exposes no storage-class remapping (kubernetesTargetParams
# accepts only recoveryTargetConfig and renameRecoveredNamespacesParams), so the
# mapping has to exist on the cluster. Each entry creates a StorageClass on the
# target whose NAME matches the source class but which is backed by the VPC block
# CSI driver, letting the restored PVC bind unchanged.
#
# Note this changes the storage characteristics: a Classic "silver" volume is
# recreated as VPC block on the given profile. Choose the profile accordingly.
resource "kubernetes_storage_class_v1" "recovery_alias" {
  provider = kubernetes.target
  for_each = local.deploy_target_cluster ? var.recovery_storage_class_aliases : {}

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/managed-by" = "terraform-ibm-iks-ocp-backup-recovery"
    }
    annotations = {
      description = "Compatibility alias created by the BRS deployable architecture so PVCs restored from a source cluster using storage class '${each.key}' can bind on this VPC cluster."
    }
  }

  # Fixed to the VPC block CSI defaults — these mirror the stock
  # ibmc-vpc-block-* classes. Only the profile varies, via the map value.
  # Anyone needing different reclaim/binding semantics should create the
  # StorageClass themselves rather than widen this interface.
  storage_provisioner    = "vpc.block.csi.ibm.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    billingType                 = "hourly"
    classVersion                = "1"
    "csi.storage.k8s.io/fstype" = "ext4"
    encrypted                   = "false"
    encryptionKey               = ""
    profile                     = each.value
    region                      = ""
    resourceGroup               = ""
    tags                        = ""
    zone                        = ""
  }

  depends_on = [data.ibm_container_cluster_config.target_cluster_config]
}

# Wait for target registration to propagate
resource "time_sleep" "wait_for_target_registration" {
  count = local.deploy_target_cluster ? 1 : 0

  depends_on = [module.target_cluster_registration]

  create_duration = "90s"
}

##############################################################################
# Backup Completion Polling
##############################################################################

# module.protect_cluster already triggers an on-demand backup run for every
# protection group when deployment_mode is "full_backup_recovery" (see
# terraform_data.trigger_backup_run in the root module). Triggering a second
# run here would race with that one, so this only polls for the backup that
# module.protect_cluster already started.
resource "terraform_data" "wait_for_backup" {
  count = local.is_full_recovery ? 1 : 0

  depends_on = [
    module.protect_cluster,
    time_sleep.wait_for_target_registration
  ]

  input = {
    url                   = module.protect_cluster.brs_instance_url
    tenant                = module.protect_cluster.brs_tenant_id
    endpoint_type         = var.brs_endpoint_type
    instance_id           = module.protect_cluster.brs_instance_guid
    api_key               = sensitive(var.ibmcloud_api_key)
    timeout_minutes       = var.recovery_wait_timeout_minutes
    poll_interval_seconds = var.recovery_poll_interval_seconds
    binaries_path         = "/tmp"
    # protection_group_id is resolved from module outputs after apply.
    # It is passed via environment variable (not interpolated into the command
    # string) so that a null/unknown value at plan time does not cause
    # "Cannot include a null value in a string template".
    protection_group_id = local.recovery_pg_id
  }

  provisioner "local-exec" {
    command     = "${path.module}/../../scripts/wait_for_backup_run.sh '${self.input.url}' '${self.input.tenant}' '${self.input.endpoint_type}' '${self.input.instance_id}' $BRS_PG_ID '${self.input.timeout_minutes}' '${self.input.poll_interval_seconds}' '${self.input.binaries_path}' > /tmp/backup_snapshot_${self.input.instance_id}.json"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
      BRS_PG_ID        = self.input.protection_group_id
    }
  }
}

##############################################################################
# Same-Cluster Recovery
##############################################################################

resource "terraform_data" "same_cluster_recovery" {
  count = local.is_full_recovery && var.recovery_type == "same-cluster" ? 1 : 0

  input = {
    url              = module.protect_cluster.brs_instance_url
    tenant           = module.protect_cluster.brs_tenant_id
    endpoint_type    = var.brs_endpoint_type
    instance_id      = module.protect_cluster.brs_instance_guid
    source_pg_id     = local.recovery_pg_id
    target_source_id = split("::", module.protect_cluster.source_registration_id)[1]
    api_key          = sensitive(var.ibmcloud_api_key)
    recovery_name    = "recovery-${local.recovery_pg_label}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
    binaries_path    = "/tmp"
    namespace_prefix = var.recovery_namespace_prefix
  }

  provisioner "local-exec" {
    # wait_for_backup_run.sh writes snapshot info to this file before this resource is applied.
    # jq is available in the Schematics environment (used by wait_for_backup_run.sh itself).
    command = <<-EOT
      SNAPSHOT_ID=$(jq -r '.snapshot_id' /tmp/backup_snapshot_${self.input.instance_id}.json)
      ${path.module}/../../scripts/trigger_cross_cluster_recovery.sh \
        '${self.input.url}' \
        '${self.input.tenant}' \
        '${self.input.endpoint_type}' \
        '${self.input.instance_id}' \
        "$BRS_PG_ID" \
        '${self.input.target_source_id}' \
        "$SNAPSHOT_ID" \
        '${self.input.recovery_name}' \
        '${self.input.namespace_prefix}' \
        '${self.input.binaries_path}'
    EOT
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
      BRS_PG_ID        = self.input.source_pg_id
    }
  }

  depends_on = [terraform_data.wait_for_backup]
}

##############################################################################
# Cross-Cluster Recovery
##############################################################################

resource "terraform_data" "cross_cluster_recovery" {
  count = local.is_full_recovery && var.recovery_type == "cross-cluster" ? 1 : 0

  input = {
    url              = module.protect_cluster.brs_instance_url
    tenant           = module.protect_cluster.brs_tenant_id
    endpoint_type    = var.brs_endpoint_type
    instance_id      = module.protect_cluster.brs_instance_guid
    source_pg_id     = local.recovery_pg_id
    target_source_id = split("::", module.target_cluster_registration[0].source_registration_id)[1]
    api_key          = sensitive(var.ibmcloud_api_key)
    recovery_name    = "cross-cluster-recovery-${local.recovery_pg_label}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
    binaries_path    = "/tmp"
    namespace_prefix = var.recovery_namespace_prefix
  }

  provisioner "local-exec" {
    # wait_for_backup_run.sh writes snapshot info to this file before this resource is applied.
    # jq is available in the Schematics environment (used by wait_for_backup_run.sh itself).
    command = <<-EOT
      SNAPSHOT_ID=$(jq -r '.snapshot_id' /tmp/backup_snapshot_${self.input.instance_id}.json)
      ${path.module}/../../scripts/trigger_cross_cluster_recovery.sh \
        '${self.input.url}' \
        '${self.input.tenant}' \
        '${self.input.endpoint_type}' \
        '${self.input.instance_id}' \
        "$BRS_PG_ID" \
        '${self.input.target_source_id}' \
        "$SNAPSHOT_ID" \
        '${self.input.recovery_name}' \
        '${self.input.namespace_prefix}' \
        '${self.input.binaries_path}'
    EOT
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
      BRS_PG_ID        = self.input.source_pg_id
    }
  }

  depends_on = [
    terraform_data.wait_for_backup,
    module.target_cluster_registration,
    time_sleep.wait_for_target_registration,
    # Alias storage classes must exist before the restore creates PVCs that
    # reference them, otherwise the PVCs stay Pending and the recovery fails.
    kubernetes_storage_class_v1.recovery_alias
  ]
}

##############################################################################
# Wait for Recovery Completion
##############################################################################

# Poll recovery status and wait for completion before refreshing the protection source
# Recovery operations are asynchronous - this ensures namespaces are fully restored
resource "terraform_data" "wait_for_recovery_completion" {
  count = local.is_full_recovery ? 1 : 0

  input = {
    url                   = module.protect_cluster.brs_instance_url
    tenant                = module.protect_cluster.brs_tenant_id
    endpoint_type         = var.brs_endpoint_type
    instance_id           = module.protect_cluster.brs_instance_guid
    api_key               = sensitive(var.ibmcloud_api_key)
    timeout_minutes       = var.recovery_wait_timeout_minutes
    poll_interval_seconds = var.recovery_poll_interval_seconds
    binaries_path         = "/tmp"
  }

  provisioner "local-exec" {
    command = <<-EOT
      RECOVERY_ID=$(cat /tmp/recovery_id_${self.input.instance_id}.txt)
      ${path.module}/../../scripts/wait_for_recovery_completion.sh \
        '${self.input.url}' \
        '${self.input.tenant}' \
        '${self.input.endpoint_type}' \
        '${self.input.instance_id}' \
        "$RECOVERY_ID" \
        '${self.input.timeout_minutes}' \
        '${self.input.poll_interval_seconds}' \
        '${self.input.binaries_path}'
    EOT
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
    }
  }

  depends_on = [
    terraform_data.same_cluster_recovery,
    terraform_data.cross_cluster_recovery
  ]
}

##############################################################################
# Refresh Protection Source After Recovery
##############################################################################

# Refresh the appropriate cluster after recovery to make recovered namespaces visible in the protection source UI
# - For same-cluster recovery: refresh the source cluster (where recovery happened)
# - For cross-cluster recovery: refresh the target cluster (where recovery happened)
resource "ibm_backup_recovery_protection_source_refresh" "post_recovery_refresh" {
  count = local.is_full_recovery ? 1 : 0

  x_ibm_tenant_id                      = module.protect_cluster.brs_tenant_id
  backup_recovery_protection_source_id = var.recovery_type == "cross-cluster" ? tonumber(split("::", module.target_cluster_registration[0].source_registration_id)[1]) : tonumber(split("::", module.protect_cluster.source_registration_id)[1])
  endpoint_type                        = var.brs_endpoint_type
  instance_id                          = module.protect_cluster.brs_instance_guid
  region                               = local.region

  depends_on = [
    terraform_data.wait_for_recovery_completion
  ]
}
