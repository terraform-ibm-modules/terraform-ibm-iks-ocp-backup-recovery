locals {
  # --- Environment type detection ---
  is_vpc     = length(regexall("Vpc$", var.connection_env_type)) > 0
  is_classic = length(regexall("Classic$", var.connection_env_type)) > 0

  # --- Recovery mode detection ---
  is_full_recovery = var.deployment_mode == "full_backup_recovery"
}
# Retrieve information about an existing VPC cluster
# Uses ibm.source_account provider — source account in cross-account deployments.
data "ibm_container_vpc_cluster" "vpc_cluster" {
  count             = local.is_vpc ? 1 : 0
  provider          = ibm.source_account
  name              = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}

# Retrieve information about an existing Classic cluster
data "ibm_container_cluster" "classic_cluster" {
  count             = local.is_classic ? 1 : 0
  provider          = ibm.source_account
  name              = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}
data "ibm_container_cluster_config" "cluster_config" {
  provider          = ibm.source_account
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

module "protect_cluster" {
  source = "../.."
  providers = {
    ibm                = ibm                # target (BRS) account — or only account in same-account mode
    ibm.source_account = ibm.source_account # source (cluster/VPC) account — same as ibm when source_ibmcloud_api_key is null
  }
  # --- Cluster ---
  cluster_id                   = var.cluster_id
  cluster_resource_group_id    = var.cluster_resource_group_id
  cluster_config_endpoint_type = var.cluster_config_endpoint_type
  add_dsc_rules_to_cluster_sg  = var.add_dsc_rules_to_cluster_sg
  add_cluster_tags             = var.add_cluster_tags
  kube_type                    = var.kube_type
  wait_till                    = var.wait_till
  wait_till_timeout            = var.wait_till_timeout
  # --- Deployment Mode ---
  deployment_mode = var.deployment_mode
  # --- BRS Instance ---
  ibmcloud_api_key          = var.ibmcloud_api_key
  brs_endpoint_type         = var.brs_endpoint_type
  existing_brs_instance_crn = var.existing_brs_instance_crn
  brs_instance_name         = var.brs_instance_name
  brs_resource_group_id     = var.brs_resource_group_id
  region                    = local.region
  # --- BRS Connection ---
  brs_connection_name       = var.brs_connection_name
  brs_create_new_connection = var.brs_create_new_connection
  connection_env_type       = var.connection_env_type
  # --- Data Source Connector (DSC) ---
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
  # --- Registration Settings ---
  registration_images = var.registration_images
  enable_auto_protect = var.enable_auto_protect
  # --- Backup Policy ---
  auto_protect_policy_name = var.auto_protect_policy_name
  protection_groups        = var.protection_groups
  policies                 = var.policies
  # --- Resource Tags ---
  resource_tags = var.resource_tags
  access_tags   = var.access_tags
  # --- Recovery Settings ---
  recovery_mode                    = var.recovery_type
  target_cluster_id                = var.target_cluster_id
  target_cluster_resource_group_id = var.target_cluster_resource_group_id
}

##############################################################################
# Virtual Private Endpoint Gateway for BRS
##############################################################################

locals {
  # Cross-account detection: S2S policy needed only when the VPC account
  # (ibm.source_account) differs from the BRS instance account (ibm).
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

  brs_vpe_active = var.create_brs_vpe && local.is_vpc

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
  provider = ibm.source_account
}

# Subnet lookups for VPE auto-discovery (skipped when vpc_subnets supplied).
data "ibm_is_subnet" "cluster_subnet" {
  count      = local.cluster_subnet_lookup_count
  provider   = ibm.source_account
  identifier = local.cluster_subnet_ids[count.index]
}

# kube-vpegw security group — created automatically by IKS/ROKS for every VPC cluster.
data "ibm_is_security_group" "kube_vpeg_sg" {
  count    = local.brs_vpe_active ? 1 : 0
  provider = ibm.source_account
  name     = "kube-vpegw-${local.resolved_vpc_id}"
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
  provider = ibm.source_account
  subnet   = each.value.id
  name     = "${local.brs_vpe_name_resolved}-${each.key}-ip"
}

# VPE Gateway — routes DSC↔BRS traffic over IBM private backbone.
resource "ibm_is_virtual_endpoint_gateway" "brs_vpe" {
  count           = local.brs_vpe_active && !var.retain_brs_vpe_on_destroy ? 1 : 0
  provider        = ibm.source_account
  name            = local.brs_vpe_name_resolved
  vpc             = local.resolved_vpc_id
  resource_group  = var.cluster_resource_group_id
  security_groups = [data.ibm_is_security_group.kube_vpeg_sg[0].id]

  target {
    crn           = module.protect_cluster.brs_instance_crn
    resource_type = "provider_cloud_service"
  }

  depends_on = [module.brs_s2s_auth]
}

resource "ibm_is_virtual_endpoint_gateway_ip" "brs_vpe_ip" {
  for_each    = local.brs_vpe_active && !var.retain_brs_vpe_on_destroy ? local.brs_vpe_subnets_map : {}
  provider    = ibm.source_account
  gateway     = ibm_is_virtual_endpoint_gateway.brs_vpe[0].id
  reserved_ip = ibm_is_subnet_reserved_ip.brs_vpe_ip[each.key].reserved_ip
}

# Protected VPE gateway — survives destroy when retain_brs_vpe_on_destroy = true.
resource "ibm_is_virtual_endpoint_gateway" "brs_vpe_retained" {
  count           = local.brs_vpe_active && var.retain_brs_vpe_on_destroy ? 1 : 0
  provider        = ibm.source_account
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

resource "ibm_is_virtual_endpoint_gateway_ip" "brs_vpe_ip_retained" {
  for_each    = local.brs_vpe_active && var.retain_brs_vpe_on_destroy ? local.brs_vpe_subnets_map : {}
  provider    = ibm.source_account
  gateway     = ibm_is_virtual_endpoint_gateway.brs_vpe_retained[0].id
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
  provider          = ibm.source_account
  name              = var.target_cluster_id
  resource_group_id = var.target_cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}

data "ibm_container_cluster_config" "target_cluster_config" {
  depends_on = [data.ibm_container_vpc_cluster.target_cluster]

  count             = local.deploy_target_cluster ? 1 : 0
  provider          = ibm.source_account
  cluster_name_id   = var.target_cluster_id
  resource_group_id = var.target_cluster_resource_group_id
  config_dir        = "${path.module}/kubeconfig"
  endpoint_type     = var.target_cluster_config_endpoint_type == "default" ? null : var.target_cluster_config_endpoint_type
  admin             = true
}

# Register target cluster with BRS
module "target_cluster_registration" {
  count  = local.deploy_target_cluster ? 1 : 0
  source = "../.."

  providers = {
    ibm                = ibm                # target (BRS) account
    ibm.source_account = ibm.source_account # source (cluster/VPC) account — same as ibm when source_ibmcloud_api_key is null
    helm               = helm.target
    kubernetes         = kubernetes.target
  }

  cluster_id                   = var.target_cluster_id
  cluster_resource_group_id    = var.target_cluster_resource_group_id
  cluster_config_endpoint_type = var.target_cluster_config_endpoint_type
  add_dsc_rules_to_cluster_sg  = var.add_dsc_rules_to_cluster_sg
  kube_type                    = var.kube_type
  ibmcloud_api_key             = var.ibmcloud_api_key

  # Use same BRS instance as source. The source's BRS instance CRN is only known
  # after apply when the source creates a new instance, so create_new_instance is
  # set explicitly to false to keep the module's count/for_each gates from
  # depending on that unknown value at plan time.
  existing_brs_instance_crn = module.protect_cluster.brs_instance_crn
  create_new_brs_instance   = false
  brs_endpoint_type         = var.brs_endpoint_type
  region                    = local.region

  # Target connection configuration
  brs_connection_name       = var.target_brs_connection_name != null ? var.target_brs_connection_name : "${var.target_cluster_id}-target-connection"
  brs_create_new_connection = var.target_brs_create_new_connection
  connection_env_type       = var.connection_env_type

  # DSC configuration for target
  dsc_chart_uri          = var.dsc_chart_uri
  dsc_name               = var.dsc_name
  dsc_replicas           = var.dsc_replicas
  dsc_namespace          = var.dsc_namespace
  dsc_helm_timeout       = var.dsc_helm_timeout
  dsc_storage_class      = var.dsc_storage_class
  create_dsc_worker_pool = var.target_create_dsc_worker_pool

  # Registration settings
  registration_images = var.registration_images
  enable_auto_protect = false # Don't auto-protect target cluster

  # No policies or protection groups for target (it's just a recovery destination)
  policies          = []
  protection_groups = null

  # Tags
  resource_tags = var.resource_tags
  access_tags   = var.access_tags

  depends_on = [
    data.ibm_container_cluster_config.target_cluster_config
  ]
}

##############################################################################
# VPE Gateway for target cluster (when target_create_brs_vpe = true)
# Routes target cluster's DSC↔BRS traffic over the IBM private backbone.
# Created here in the DA because the root module no longer manages VPE.
##############################################################################

locals {
  target_brs_vpe_active = var.target_create_brs_vpe && local.is_vpc && local.deploy_target_cluster

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
  provider   = ibm.source_account
  identifier = local.target_cluster_subnet_ids[count.index]
}

data "ibm_is_security_group" "target_kube_vpeg_sg" {
  count    = local.target_brs_vpe_active ? 1 : 0
  provider = ibm.source_account
  name     = "kube-vpegw-${local.target_resolved_vpc_id}"
}

resource "ibm_is_subnet_reserved_ip" "target_brs_vpe_ip" {
  for_each = local.target_brs_vpe_active ? local.target_brs_vpe_subnets_map : {}
  provider = ibm.source_account
  subnet   = each.value.id
  name     = "${local.target_brs_vpe_name_resolved}-${each.key}-ip"
}

resource "ibm_is_virtual_endpoint_gateway" "target_brs_vpe" {
  count           = local.target_brs_vpe_active ? 1 : 0
  provider        = ibm.source_account
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
  provider    = ibm.source_account
  gateway     = ibm_is_virtual_endpoint_gateway.target_brs_vpe[0].id
  reserved_ip = ibm_is_subnet_reserved_ip.target_brs_vpe_ip[each.key].reserved_ip
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
    time_sleep.wait_for_target_registration
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
