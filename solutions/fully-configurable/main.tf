locals {
  # --- Environment type detection ---
  is_vpc     = length(regexall("Vpc$", var.source_connection_env_type)) > 0
  is_classic = length(regexall("Classic$", var.source_connection_env_type)) > 0

  # --- Recovery mode detection ---
  is_full_recovery = var.deployment_mode == "full_backup_recovery"
}
# Retrieve information about an existing VPC cluster
# Uses ibm.source_cluster provider — source account in cross-account deployments.
data "ibm_container_vpc_cluster" "vpc_cluster" {
  count             = local.is_vpc ? 1 : 0
  provider          = ibm.source_cluster
  name              = var.source_cluster_id
  resource_group_id = var.source_cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}

# Retrieve information about an existing Classic cluster
data "ibm_container_cluster" "classic_cluster" {
  count             = local.is_classic ? 1 : 0
  provider          = ibm.source_cluster
  name              = var.source_cluster_id
  resource_group_id = var.source_cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}
data "ibm_container_cluster_config" "cluster_config" {
  provider          = ibm.source_cluster
  cluster_name_id   = var.source_cluster_id
  resource_group_id = var.source_cluster_resource_group_id
  config_dir        = "${path.module}/kubeconfig"
  endpoint_type     = var.source_cluster_config_endpoint_type != "default" ? var.source_cluster_config_endpoint_type : null
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
  resource_group_id         = var.brs_resource_group_id != null ? var.brs_resource_group_id : var.source_cluster_resource_group_id
  ibmcloud_api_key          = var.ibmcloud_api_key
  instance_name             = var.brs_instance_name
  service_type              = var.brs_service_type
  existing_brs_instance_crn = var.existing_brs_instance_crn != null && var.existing_brs_instance_crn != "" ? var.existing_brs_instance_crn : null
  create_new_instance       = var.create_new_brs_instance
  connection_name           = var.source_brs_connection_name
  create_new_connection     = var.source_brs_create_new_connection
  resource_tags             = var.resource_tags
  access_tags               = var.access_tags
  endpoint_type             = var.brs_endpoint_type
  connection_env_type       = var.source_connection_env_type
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
  cluster_id                   = var.source_cluster_id
  cluster_resource_group_id    = var.source_cluster_resource_group_id
  cluster_config_endpoint_type = var.source_cluster_config_endpoint_type
  kube_type                    = var.source_kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  connection_env_type          = var.source_connection_env_type
  ibmcloud_api_key             = var.source_ibmcloud_api_key != null ? var.source_ibmcloud_api_key : var.ibmcloud_api_key

  # DSC configuration for source cluster
  dsc_chart_uri           = var.dsc_chart_uri
  dsc_name                = var.dsc_name
  dsc_replicas            = var.dsc_replicas
  dsc_namespace           = var.dsc_namespace
  dsc_helm_timeout        = var.dsc_helm_timeout
  dsc_storage_class       = var.source_dsc_storage_class
  create_dsc_worker_pool  = var.source_create_dsc_worker_pool
  dsc_worker_pool_zones   = var.dsc_worker_pool_zones
  dsc_worker_pool_flavor  = var.source_dsc_worker_pool_flavor
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
  cluster_id                   = var.source_cluster_id
  cluster_crn                  = local.is_classic ? try(data.ibm_container_cluster.classic_cluster[0].crn, null) : try(data.ibm_container_vpc_cluster.vpc_cluster[0].crn, null)
  cluster_endpoint             = local.is_classic ? (var.source_cluster_config_endpoint_type == "private" ? try(data.ibm_container_cluster.classic_cluster[0].private_service_endpoint_url, null) : try(data.ibm_container_cluster.classic_cluster[0].public_service_endpoint_url, null)) : (var.source_cluster_config_endpoint_type == "private" ? try(data.ibm_container_vpc_cluster.vpc_cluster[0].private_service_endpoint_url, null) : try(data.ibm_container_vpc_cluster.vpc_cluster[0].public_service_endpoint_url, null))
  cluster_resource_group_id    = var.source_cluster_resource_group_id
  cluster_config_endpoint_type = var.source_cluster_config_endpoint_type
  add_cluster_tags             = var.add_cluster_tags
  kube_type                    = var.source_kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  connection_env_type          = var.source_connection_env_type
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

  brs_vpe_name_resolved = var.source_brs_vpe_name != null ? var.source_brs_vpe_name : "${lower(var.source_brs_connection_name)}-vpe"

  # Subnet auto-discovery from existing cluster worker pools.
  # When vpc_subnets is supplied explicitly (e.g. new cluster created in the same apply)
  # the lookup is skipped so the count is always plan-time-static.
  cluster_subnet_ids = local.brs_vpe_active && local.is_vpc && length(var.source_vpc_subnets) == 0 ? distinct(flatten(
    data.ibm_container_vpc_cluster.vpc_cluster[*].worker_pools[*].zones[*].subnets[*].id
  )) : []
  cluster_subnet_lookup_count = length(local.cluster_subnet_ids) > 0 ? length(local.cluster_subnet_ids) : 0

  resolved_vpc_id = var.source_vpc_id != null ? var.source_vpc_id : (
    local.cluster_subnet_lookup_count > 0 ? data.ibm_is_subnet.cluster_subnet[0].vpc : null
  )
  resolved_vpc_subnets = length(var.source_vpc_subnets) > 0 ? var.source_vpc_subnets : [
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
  # auto_delete=true is invalid for an unbound reserved IP (VPC API rejects it).
  # prevent_destroy keeps these IPs alive across terraform destroy — the VPE is
  # shared infrastructure and must not be torn down with the workspace.
  auto_delete = false

  lifecycle {
    prevent_destroy = true
  }
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
  resource_group  = var.source_cluster_resource_group_id
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
  target_is_vpc = length(regexall("Vpc$", coalesce(var.target_connection_env_type, var.source_connection_env_type))) > 0
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
  resource_group_id         = var.brs_resource_group_id != null ? var.brs_resource_group_id : var.source_cluster_resource_group_id
  ibmcloud_api_key          = var.ibmcloud_api_key
  instance_name             = var.brs_instance_name
  existing_brs_instance_crn = module.brs_instance.brs_instance_crn
  create_new_instance       = false
  connection_name           = var.target_brs_connection_name != null ? var.target_brs_connection_name : "${var.target_cluster_id}-target-connection"
  create_new_connection     = var.target_brs_create_new_connection
  resource_tags             = var.resource_tags
  access_tags               = var.access_tags
  endpoint_type             = var.brs_endpoint_type
  connection_env_type       = var.target_connection_env_type != null ? var.target_connection_env_type : var.source_connection_env_type
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
  kube_type                    = var.target_kube_type != null ? var.target_kube_type : var.source_kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  connection_env_type          = var.target_connection_env_type != null ? var.target_connection_env_type : var.source_connection_env_type
  ibmcloud_api_key             = var.target_ibmcloud_api_key != null ? var.target_ibmcloud_api_key : (var.source_ibmcloud_api_key != null ? var.source_ibmcloud_api_key : var.ibmcloud_api_key)

  # DSC configuration for target
  dsc_chart_uri          = var.dsc_chart_uri
  dsc_name               = var.dsc_name
  dsc_replicas           = var.dsc_replicas
  dsc_namespace          = var.dsc_namespace
  dsc_helm_timeout       = var.dsc_helm_timeout
  dsc_storage_class      = var.target_dsc_storage_class
  create_dsc_worker_pool = var.target_create_dsc_worker_pool
  dsc_worker_pool_flavor = var.target_dsc_worker_pool_flavor

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
  cluster_crn                  = try(data.ibm_container_vpc_cluster.target_cluster[0].crn, null)
  cluster_endpoint             = var.target_cluster_config_endpoint_type == "private" ? try(data.ibm_container_vpc_cluster.target_cluster[0].private_service_endpoint_url, null) : try(data.ibm_container_vpc_cluster.target_cluster[0].public_service_endpoint_url, null)
  cluster_resource_group_id    = var.target_cluster_resource_group_id
  cluster_config_endpoint_type = var.target_cluster_config_endpoint_type
  kube_type                    = var.target_kube_type != null ? var.target_kube_type : var.source_kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  ibmcloud_api_key             = var.ibmcloud_api_key

  # BRS prerequisite inputs — same instance as source, target's own connection
  brs_endpoint_type        = var.brs_endpoint_type
  connection_env_type      = var.target_connection_env_type != null ? var.target_connection_env_type : var.source_connection_env_type
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
  target_brs_vpe_active = var.create_target_cluster_brs_vpe_gateway && local.target_is_vpc && local.deploy_target_cluster

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
  # auto_delete=true is invalid for an unbound reserved IP (VPC API rejects it).
  # prevent_destroy keeps these IPs alive across terraform destroy — the VPE is
  # shared infrastructure and must not be torn down with the workspace.
  auto_delete = false

  lifecycle {
    prevent_destroy = true
  }
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

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [module.target_cluster_registration]
}

resource "ibm_is_virtual_endpoint_gateway_ip" "target_brs_vpe_ip" {
  for_each    = local.target_brs_vpe_active ? local.target_brs_vpe_subnets_map : {}
  provider    = ibm.target_cluster
  gateway     = ibm_is_virtual_endpoint_gateway.target_brs_vpe[0].id
  reserved_ip = ibm_is_subnet_reserved_ip.target_brs_vpe_ip[each.key].reserved_ip

  lifecycle {
    prevent_destroy = true
  }
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

  triggers_replace = {
    protection_group_id = local.recovery_pg_id
  }

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
    # Write snapshot JSON and also write snapshot_id to a file named by
    # self.id (the terraform_data UUID, stable in state after creation) so
    # downstream resources can reference it by a path that is unknown at plan
    # time (self.id is only known after apply), deferring any file() reads.
    command     = "${path.module}/../../scripts/wait_for_backup_run.sh '${self.input.url}' '${self.input.tenant}' '${self.input.endpoint_type}' '${self.input.instance_id}' $BRS_PG_ID '${self.input.timeout_minutes}' '${self.input.poll_interval_seconds}' '${self.input.binaries_path}' | tee /tmp/backup_snapshot_${self.input.instance_id}.json | jq -r '.snapshot_id' | tee /tmp/snapshot_id_${self.input.instance_id}.txt /tmp/snapshot_id_${self.id}.txt > /dev/null"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
      BRS_PG_ID        = self.input.protection_group_id
    }
  }
}

##############################################################################
# Snapshot info — read after wait_for_backup writes /tmp/snapshot_id_<id>.txt
##############################################################################

# Tombstone: local_file.snapshot_id existed in older state. The empty lifecycle
# block allows terraform refresh/destroy to reconcile it from state without
# calling file(). Will be absent from state after the next destroy.
resource "local_file" "snapshot_id" {
  count    = 0
  content  = ""
  filename = "${path.module}/snapshot_id.txt"
  lifecycle {
    ignore_changes = all
  }
}

# Stores the snapshot_id in Terraform state without any file() call at plan time.
#
# PROBLEM with file() in a resource attribute:
#   Terraform evaluates ALL resource attribute expressions during plan — even
#   attributes protected by ignore_changes — to compute the diff. If the path
#   is known at plan time (e.g. keyed by instance_guid which is always in state)
#   file() fires immediately and fails on fresh Schematics workers where /tmp
#   files don't exist yet.
#
# SOLUTION — provisioner writes snapshot_id; terraform_data.output carries it:
#   Step 1 (snapshot_id_writer): a terraform_data whose triggers_replace depends
#     on wait_for_backup[0].id (unknown on first plan, known after). Its
#     provisioner reads /tmp/snapshot_id_<wait_for_backup_id>.txt and writes the
#     content to its own output file keyed by its OWN .id (also unknown on first
#     plan). No file() call in any attribute expression.
#   Step 2 (snapshot_id): a terraform_data whose input uses file() keyed by
#     snapshot_id_writer[0].id — unknown at plan time (first run), so file() is
#     deferred to apply. After first apply both IDs are in state; subsequent plans
#     see known IDs but the resource is NOT replaced (triggers_replace only fires
#     when wait_for_backup is replaced), so the expressions are never re-evaluated
#     against live state — Terraform just compares against the state value.
#
# On new backup runs: wait_for_backup is replaced → snapshot_id_writer is
#   replaced (triggers_replace) → snapshot_id is replaced (triggers_replace) →
#   file() runs at apply time when the new /tmp files exist.

# Step 1: write snapshot_id to a file keyed by this resource's own .id (unknown
# at plan time), so the Step 2 file() path is also unknown at plan time.
resource "terraform_data" "snapshot_id_writer" {
  count = local.is_full_recovery ? 1 : 0

  triggers_replace = [terraform_data.wait_for_backup[0].id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "cp /tmp/snapshot_id_${terraform_data.wait_for_backup[0].id}.txt /tmp/snapshot_id_out_${self.id}.txt"
  }

  depends_on = [terraform_data.wait_for_backup]
}

# Step 2: read the file written by Step 1. Path keyed by snapshot_id_writer[0].id
# — unknown at first plan → file() deferred to apply. After first apply the value
# is stored in .input and never re-read from disk (triggers_replace = writer means
# this only re-runs when writer re-runs, i.e. when wait_for_backup is replaced).
resource "terraform_data" "snapshot_id" {
  count = local.is_full_recovery ? 1 : 0

  triggers_replace = [terraform_data.snapshot_id_writer[0].id]

  input = try(trimspace(file("/tmp/snapshot_id_out_${terraform_data.snapshot_id_writer[0].id}.txt")), "")

  lifecycle {
    ignore_changes = [input]
  }

  depends_on = [terraform_data.snapshot_id_writer]
}

locals {
  # snapshot_id is read from Terraform state (.input), never from /tmp.
  # Always known after first apply. Unknown at first plan → snapshot_data
  # is null → ibm_backup_recovery is correctly deferred to apply.
  snapshot_data = (
    local.is_full_recovery &&
    length(terraform_data.snapshot_id) > 0 &&
    terraform_data.snapshot_id[0].output != null
    ) ? {
    snapshot_id = tostring(terraform_data.snapshot_id[0].output)
  } : null
}

##############################################################################
# Recovery (same-cluster and cross-cluster)
#
# PROVIDER LIMITATION (ibm-cloud/ibm v2.4.0):
#   ibm_backup_recovery has a CustomizeDiff that marks ALL fields immutable.
#   It fires for every plan computation — even with ignore_changes = all and
#   even for create-before-destroy replacements — any time a config attribute
#   differs from state at plan time. Because local.recovery_pg_id is
#   (known after apply) whenever the protection group is being recreated
#   in the same apply, any replace_triggered_by on ibm_backup_recovery
#   consistently triggers this error:
#
#     "[ERROR] Resource ibm_backup_recovery cannot be updated. Field: kubernetes_params"
#
#   The fix: replace ibm_backup_recovery with a script-based approach.
#   terraform_data.recovery_trigger calls scripts/trigger_recovery.sh
#   (which POSTs /v2/data-protect/recoveries directly) and writes the
#   recovery_id to /tmp. terraform_data.recovery_id reads that file and
#   stores the recovery_id in .output for use by wait_for_recovery_completion.
#
#   ibm_backup_recovery.recovery is retained as a zero-count tombstone so
#   that existing state records are not destroyed (BRS API rejects DELETE
#   on recovery records — they are immutable audit history). Remove orphaned
#   state entries manually if needed:
#     terraform state rm 'ibm_backup_recovery.recovery[0]'
##############################################################################

# Step 1 — Trigger the recovery via script and write recovery_id to a file
# keyed by self.id (unknown at plan time → defers file write to apply).
# Triggered on every new backup run or new target registration.
resource "terraform_data" "recovery_trigger" {
  count = local.is_full_recovery ? 1 : 0

  triggers_replace = {
    wait_for_backup     = terraform_data.wait_for_backup[0].id
    target_registration = var.recovery_type == "cross-cluster" ? module.target_cluster_registration[0].source_registration_id : ""
  }

  input = {
    url                  = module.protect_cluster.brs_instance_url
    tenant               = module.protect_cluster.brs_tenant_id
    endpoint_type        = var.brs_endpoint_type
    instance_id          = module.protect_cluster.brs_instance_guid
    api_key              = sensitive(var.ibmcloud_api_key)
    pg_id                = local.recovery_pg_id
    namespace_prefix     = var.recovery_namespace_prefix
    target_source_id     = var.recovery_type == "cross-cluster" ? tostring(tonumber(split("::", module.target_cluster_registration[0].source_registration_id)[1])) : ""
    binaries_path        = "/tmp"
    recovery_type        = var.recovery_type
    recovery_pg_label    = local.recovery_pg_label
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # Capture only the last line of stdout (the recovery_id) so that
    # script progress/info lines written to stdout do not corrupt the file.
    command = <<-EOT
      ${path.module}/../../scripts/trigger_recovery.sh \
        '${self.input.url}' \
        '${self.input.tenant}' \
        '${self.input.endpoint_type}' \
        '${self.input.instance_id}' \
        '${self.input.pg_id}' \
        "${tostring(terraform_data.snapshot_id[0].output)}" \
        "${self.input.recovery_type == "cross-cluster" ? "cross-cluster-" : ""}recovery-${self.input.recovery_pg_label}-$(date +%Y%m%d-%H%M)" \
        '${self.input.namespace_prefix}' \
        '${self.input.target_source_id}' \
        '${self.input.binaries_path}' \
        | tail -n1 > /tmp/recovery_id_out_${self.id}.txt
    EOT
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
    }
  }

  depends_on = [
    terraform_data.snapshot_id,
    terraform_data.wait_for_backup,
    module.target_cluster_registration,
    time_sleep.wait_for_target_registration,
  ]
}

# Step 2 — Read recovery_id written by recovery_trigger into Terraform state.
# Uses the snapshot_id pattern: input uses file() keyed by recovery_trigger[0].id
# which is unknown at plan time on first create → deferred to apply. After first
# apply the id is known and ignore_changes = [input] prevents re-reads.
resource "terraform_data" "recovery_id" {
  count = local.is_full_recovery ? 1 : 0

  triggers_replace = [terraform_data.recovery_trigger[0].id]

  input = try(trimspace(file("/tmp/recovery_id_out_${terraform_data.recovery_trigger[0].id}.txt")), "")

  lifecycle {
    ignore_changes = [input]
  }

  depends_on = [terraform_data.recovery_trigger]
}

# Tombstone: ibm_backup_recovery.recovery existed in older state. count = 0 so
# it is not managed going forward. BRS rejects DELETE on recovery records
# (immutable audit history) so any existing state entry is left as-is.
# Remove orphaned entries manually if needed:
#   terraform state rm 'ibm_backup_recovery.recovery[0]'
resource "ibm_backup_recovery" "recovery" {
  count = 0

  x_ibm_tenant_id      = ""
  name                 = ""
  snapshot_environment = "kKubernetes"
  endpoint_type        = "public"
  instance_id          = ""
  region               = ""

  kubernetes_params {
    recovery_action = "RecoverNamespaces"
    recover_namespace_params {
      target_environment = "kKubernetes"
      kubernetes_target_params {
        objects {
          snapshot_id         = ""
          protection_group_id = ""
        }
        recovery_target_config {
          recover_to_new_source = false
        }
        rename_recovered_namespaces_params {
          prefix = ""
        }
      }
    }
  }

  lifecycle {
    ignore_changes = all
  }
}

##############################################################################
# Wait for Recovery Completion
##############################################################################

# Poll recovery status and wait for completion before refreshing the protection source.
# Recovery operations are asynchronous — this ensures namespaces are fully restored.
# The recovery_id is read from terraform_data.recovery_id[0].output (stored in state
# after recovery_trigger's provisioner runs).
resource "terraform_data" "wait_for_recovery_completion" {
  count = local.is_full_recovery ? 1 : 0

  # Re-run whenever a new recovery is triggered (recovery_trigger replaced).
  triggers_replace = {
    recovery_trigger_id = terraform_data.recovery_trigger[0].id
  }

  input = {
    url                   = module.protect_cluster.brs_instance_url
    tenant                = module.protect_cluster.brs_tenant_id
    endpoint_type         = var.brs_endpoint_type
    instance_id           = module.protect_cluster.brs_instance_guid
    api_key               = sensitive(var.ibmcloud_api_key)
    timeout_minutes       = var.recovery_wait_timeout_minutes
    poll_interval_seconds = var.recovery_poll_interval_seconds
    binaries_path         = "/tmp"
    recovery_id           = tostring(terraform_data.recovery_id[0].output)
  }

  provisioner "local-exec" {
    # on_failure = continue: recovery runs asynchronously in BRS. If the
    # Schematics job wall-clock timeout kills this poller before recovery
    # finishes, the apply still succeeds. The recovery_id is in state and
    # the BRS UI shows live status.
    on_failure = continue

    command = <<-EOT
      ${path.module}/../../scripts/wait_for_recovery_completion.sh \
        '${self.input.url}' \
        '${self.input.tenant}' \
        '${self.input.endpoint_type}' \
        '${self.input.instance_id}' \
        '${self.input.recovery_id}' \
        '${self.input.timeout_minutes}' \
        '${self.input.poll_interval_seconds}' \
        '${self.input.binaries_path}'
    EOT
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
    }
  }

  depends_on = [terraform_data.recovery_id]
}

##############################################################################
# Refresh Protection Source After Recovery
##############################################################################

# Refresh the appropriate cluster after recovery to make recovered namespaces
# visible in the protection source UI.
# - For same-cluster recovery: refresh the source cluster (where recovery happened)
# - For cross-cluster recovery: refresh the target cluster (where recovery happened)
resource "ibm_backup_recovery_protection_source_refresh" "post_recovery_refresh" {
  count = local.is_full_recovery ? 1 : 0

  x_ibm_tenant_id                      = module.protect_cluster.brs_tenant_id
  backup_recovery_protection_source_id = var.recovery_type == "cross-cluster" ? tonumber(split("::", module.target_cluster_registration[0].source_registration_id)[1]) : tonumber(split("::", module.protect_cluster.source_registration_id)[1])
  endpoint_type                        = var.brs_endpoint_type
  instance_id                          = module.protect_cluster.brs_instance_guid
  region                               = local.region

  depends_on = [terraform_data.wait_for_recovery_completion]
}
