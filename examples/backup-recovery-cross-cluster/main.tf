##############################################################################
# backup-recovery-cross-cluster example
#
# Demonstrates BRS VPE connectivity for two clusters within the SAME IBM Cloud
# account — a source cluster that is backed up and a target cluster that
# receives cross-cluster recoveries.
#
# Both clusters live in the same account but in separate VPCs so that each
# gets its own VPE Gateway bound to the BRS instance.
#
#   SOURCE cluster  (ibm / ibm.cluster = ibm)
#     - IKS VPC cluster  (created or existing)
#     - VPC + subnet + public gateway  (created when source_cluster_name_id = null)
#     - VPE Gateway bound to source VPC  (create_brs_vpe = true)
#
#   TARGET cluster  (ibm / ibm.cluster = ibm)
#     - IKS VPC cluster  (created or existing)
#     - VPC + subnet + public gateway  (created when target_cluster_name_id = null)
#     - VPE Gateway bound to target VPC  (create_brs_vpe = true)
#
# The BRS instance is created once (by module.source_backup_recovery) and
# reused by module.target_backup_recovery via create_new_brs_instance = false.
#
# Apply order (enforced by the module's internal dependency graph)
# -----------------------------------------------------------------------
# Track A: BRS instance → source connection → source registration token
# Track B: source VPC → source cluster
# Gate: source VPEG live + source cluster ready → DSC Helm → source registration
#
# Track C: target VPC → target cluster
# Gate: target VPEG live + target cluster ready → target DSC Helm → target registration
# Gate: target registration complete → backup polling → cross-cluster recovery
#
# After apply, exec into the DSC pod on each cluster and run:
#   getent hosts <brs_private_hostname>
# The result should resolve to the VPEG reserved IP, confirming that
# DSC→BRS traffic routes through the IBM private backbone.
##############################################################################

locals {
  source_cluster_id = var.source_cluster_name_id != null ? var.source_cluster_name_id : ibm_container_vpc_cluster.source_cluster[0].id
  target_cluster_id = var.target_cluster_name_id != null ? var.target_cluster_name_id : ibm_container_vpc_cluster.target_cluster[0].id

  # VPC ID and subnet list for the source VPE Gateway.
  # Supplied explicitly so plan-time values are known when the cluster is
  # created in the same apply (worker-pool auto-discovery only works post-apply).
  source_vpc_id = ibm_is_vpc.source_vpc[0].id
  source_vpc_subnets = [
    {
      name = ibm_is_subnet.source_subnet[0].name
      id   = ibm_is_subnet.source_subnet[0].id
      zone = ibm_is_subnet.source_subnet[0].zone
    }
  ]

  # VPC ID and subnet list for the target VPE Gateway.
  target_vpc_id = ibm_is_vpc.target_vpc[0].id
  target_vpc_subnets = [
    {
      name = ibm_is_subnet.target_subnet[0].name
      id   = ibm_is_subnet.target_subnet[0].id
      zone = ibm_is_subnet.target_subnet[0].zone
    }
  ]

  # Namespace created on the source cluster for the test workload.
  source_namespace = kubernetes_namespace_v1.source_app.metadata[0].name

  # Snapshot metadata written by wait_for_source_backup; null when recovery is disabled.
  snapshot_data = var.enable_recovery ? jsondecode(data.local_file.snapshot_info[0].content) : null
}

##############################################################################
# Resource Group (single group — same account)
##############################################################################

module "resource_group" {
  source                       = "terraform-ibm-modules/resource-group/ibm"
  version                      = "1.6.0"
  resource_group_name          = var.resource_group == null ? "${var.prefix}-resource-group" : null
  existing_resource_group_name = var.resource_group
}

##############################################################################
# Source VPC + subnet + gateway  (created when source_cluster_name_id = null)
##############################################################################

resource "ibm_is_vpc" "source_vpc" {
  count = var.source_cluster_name_id == null ? 1 : 0

  name                      = "${var.prefix}-source-vpc"
  resource_group            = module.resource_group.resource_group_id
  address_prefix_management = "auto"
  tags                      = var.resource_tags
}

resource "ibm_is_public_gateway" "source_gateway" {
  count = var.source_cluster_name_id == null ? 1 : 0

  name           = "${var.prefix}-source-gateway"
  vpc            = ibm_is_vpc.source_vpc[0].id
  resource_group = module.resource_group.resource_group_id
  zone           = "${var.region}-1"
}

resource "ibm_is_subnet" "source_subnet" {
  count = var.source_cluster_name_id == null ? 1 : 0

  name                     = "${var.prefix}-source-subnet"
  vpc                      = ibm_is_vpc.source_vpc[0].id
  resource_group           = module.resource_group.resource_group_id
  zone                     = "${var.region}-1"
  total_ipv4_address_count = 256
  public_gateway           = ibm_is_public_gateway.source_gateway[0].id
}

##############################################################################
# Target VPC + subnet + gateway  (created when target_cluster_name_id = null)
##############################################################################

resource "ibm_is_vpc" "target_vpc" {
  count = var.target_cluster_name_id == null ? 1 : 0

  name                      = "${var.prefix}-target-vpc"
  resource_group            = module.resource_group.resource_group_id
  address_prefix_management = "auto"
  tags                      = var.resource_tags
}

resource "ibm_is_public_gateway" "target_gateway" {
  count = var.target_cluster_name_id == null ? 1 : 0

  name           = "${var.prefix}-target-gateway"
  vpc            = ibm_is_vpc.target_vpc[0].id
  resource_group = module.resource_group.resource_group_id
  zone           = "${var.region}-1"
}

resource "ibm_is_subnet" "target_subnet" {
  count = var.target_cluster_name_id == null ? 1 : 0

  name                     = "${var.prefix}-target-subnet"
  vpc                      = ibm_is_vpc.target_vpc[0].id
  resource_group           = module.resource_group.resource_group_id
  zone                     = "${var.region}-1"
  total_ipv4_address_count = 256
  public_gateway           = ibm_is_public_gateway.target_gateway[0].id
}

##############################################################################
# Source IKS cluster  (created when source_cluster_name_id = null)
##############################################################################

resource "ibm_container_vpc_cluster" "source_cluster" {
  count = var.source_cluster_name_id == null ? 1 : 0

  name                                = "${var.prefix}-source-cluster"
  vpc_id                              = ibm_is_vpc.source_vpc[0].id
  flavor                              = "bx2.4x16"
  force_delete_storage                = true
  resource_group_id                   = module.resource_group.resource_group_id
  worker_count                        = 2
  disable_outbound_traffic_protection = true
  tags                                = var.resource_tags

  zones {
    subnet_id = ibm_is_subnet.source_subnet[0].id
    name      = "${var.region}-1"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

##############################################################################
# Target IKS cluster  (created when target_cluster_name_id = null)
##############################################################################

resource "ibm_container_vpc_cluster" "target_cluster" {
  count = var.target_cluster_name_id == null ? 1 : 0

  name                                = "${var.prefix}-target-cluster"
  vpc_id                              = ibm_is_vpc.target_vpc[0].id
  flavor                              = "bx2.4x16"
  force_delete_storage                = true
  resource_group_id                   = module.resource_group.resource_group_id
  worker_count                        = 2
  disable_outbound_traffic_protection = true
  tags                                = var.resource_tags

  zones {
    subnet_id = ibm_is_subnet.target_subnet[0].id
    name      = "${var.region}-1"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

##############################################################################
# Cluster kubeconfigs
##############################################################################

data "ibm_container_cluster_config" "source_cluster_config" {
  cluster_name_id   = local.source_cluster_id
  resource_group_id = module.resource_group.resource_group_id
  admin             = true
  endpoint_type     = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
}

data "ibm_container_cluster_config" "target_cluster_config" {
  cluster_name_id   = local.target_cluster_id
  resource_group_id = module.resource_group.resource_group_id
  admin             = true
  endpoint_type     = var.cluster_config_endpoint_type != "default" ? var.cluster_config_endpoint_type : null
}

# Brief pause after kubeconfig is available to let RBAC sync propagate
resource "time_sleep" "wait_clusters" {
  depends_on = [
    data.ibm_container_cluster_config.source_cluster_config,
    data.ibm_container_cluster_config.target_cluster_config,
  ]
  create_duration = "60s"
}

##############################################################################
# Test workload on source cluster
##############################################################################

resource "kubernetes_namespace_v1" "source_app" {
  provider = kubernetes.source

  metadata {
    name = "${var.prefix}-source-app"
    labels = {
      "backup-enabled" = "true"
      "environment"    = "production"
    }
  }

  depends_on = [time_sleep.wait_clusters]
}

# StatefulSet with volumeClaimTemplates — BRS requires StatefulSet PVCs for
# snapshot-based backups; Deployment PVCs cause restore PV-binding conflicts.
resource "kubernetes_stateful_set_v1" "source_app" {
  #checkov:skip=CKV_K8S_8:Test workload - liveness probe not required
  #checkov:skip=CKV_K8S_9:Test workload - readiness probe not required
  #checkov:skip=CKV_K8S_28:Test workload - NET_RAW capability not dropped
  #checkov:skip=CKV_K8S_29:Test workload - security context not applied
  #checkov:skip=CKV_K8S_30:Test workload - container security context not applied
  #checkov:skip=CKV_K8S_14:Test workload - using latest tag for simplicity
  #checkov:skip=CKV_K8S_43:Test workload - image digest not used
  provider = kubernetes.source

  metadata {
    name      = "sample-app-with-data"
    namespace = local.source_namespace
    labels = {
      app = "sample-app-with-data"
    }
  }

  spec {
    replicas     = 1
    service_name = "sample-app"

    selector {
      match_labels = {
        app = "sample-app-with-data"
      }
    }

    volume_claim_template {
      metadata {
        name = "data-storage"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "ibmc-vpc-block-metro-5iops-tier"
        resources {
          requests = {
            storage = "10Gi"
          }
        }
      }
    }

    template {
      metadata {
        labels = {
          app = "sample-app-with-data"
        }
      }
      spec {
        init_container {
          name    = "data-writer"
          image   = "icr.io/ext/cohesity/busybox:latest"
          command = ["sh", "-c"]
          args = [
            <<-EOT
              echo 'Generating cross-cluster backup test data...'
              dd if=/dev/urandom of=/data/testfile.dat bs=1M count=100
              echo "Backup test data - $(date)" > /data/backup-info.txt
              echo 'Init container complete'
            EOT
          ]
          volume_mount {
            name       = "data-storage"
            mount_path = "/data"
          }
        }

        container {
          name    = "app"
          image   = "icr.io/ext/cohesity/busybox:latest"
          command = ["sh", "-c", "echo 'App running'; sleep infinity"]
          volume_mount {
            name       = "data-storage"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.source_app]

  wait_for_rollout = false
}

resource "terraform_data" "wait_for_source_workload" {
  triggers_replace = {
    namespace   = local.source_namespace
    statefulset = kubernetes_stateful_set_v1.source_app.metadata[0].name
    kubeconfig  = data.ibm_container_cluster_config.source_cluster_config.config_file_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${self.triggers_replace.kubeconfig}"
      echo "Waiting for StatefulSet ${self.triggers_replace.statefulset} in namespace ${self.triggers_replace.namespace}..."
      kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=300s \
        statefulset/${self.triggers_replace.statefulset} \
        -n ${self.triggers_replace.namespace}
      echo "StatefulSet is ready!"
    EOT
  }

  depends_on = [
    kubernetes_stateful_set_v1.source_app,
    kubernetes_namespace_v1.source_app,
  ]
}

##############################################################################
# Source cluster — BRS backup & recovery module
#
# ibm         = ibm   → BRS instance, connection, policies live in this account
# ibm.cluster = ibm   → cluster data sources, DSC worker pool, VPEG (same account)
#
# create_brs_vpe = true → VPEG created in source VPC so DSC→BRS traffic stays
#                         on the IBM private backbone instead of the public internet.
# vpc_id / vpc_subnets  → supplied explicitly: cluster created in same apply so
#                         auto-discovery from worker pools would be unknown at plan time.
##############################################################################

module "source_backup_recovery" {
  source = "../.."
  providers = {
    ibm         = ibm
    ibm.cluster = ibm
    helm        = helm.source
    kubernetes  = kubernetes.source
  }

  # ---- Cluster ----
  cluster_id                   = local.source_cluster_id
  cluster_resource_group_id    = module.resource_group.resource_group_id
  cluster_config_endpoint_type = var.cluster_config_endpoint_type
  add_dsc_rules_to_cluster_sg  = false
  kube_type                    = "kubernetes"
  connection_env_type          = "kIksVpc"
  ibmcloud_api_key             = var.ibmcloud_api_key
  region                       = var.region
  dsc_storage_class            = "ibmc-vpc-block-metro-5iops-tier"
  dsc_worker_pool_zones        = 1
  enable_auto_protect          = false

  # ---- BRS instance ----
  existing_brs_instance_crn = var.existing_brs_instance_crn
  brs_instance_name         = "${var.prefix}-brs-instance"
  brs_connection_name       = var.source_connection_name != null ? var.source_connection_name : "${var.prefix}-source-connection"
  brs_create_new_connection = var.brs_create_new_connection

  # Use public endpoint so Terraform (CI/workstation) can reach the BRS API.
  # DSC traffic routes privately via the VPE Gateway.
  brs_endpoint_type = "public"

  # ---- VPE Gateway (source VPC) ----
  create_brs_vpe = true
  brs_vpe_name   = "${var.prefix}-source-vpe"
  vpc_id         = local.source_vpc_id
  vpc_subnets    = local.source_vpc_subnets

  # ---- Backup policy ----
  policies = [{
    name              = "${var.prefix}-continuous-backup"
    create_new_policy = true
    schedule = {
      unit = "Minutes"
      minute_schedule = {
        frequency = 240
      }
    }
    retention = {
      unit     = "Days"
      duration = 7
    }
  }]

  # ---- Protection group ----
  protection_groups = [{
    name        = "${var.prefix}-source-pg"
    policy_name = "${var.prefix}-continuous-backup"
    description = "Backup source cluster workloads"
    priority    = "kHigh"

    enable_indexing       = true
    leverage_csi_snapshot = true
    non_snapshot_backup   = false
    volume_backup_failure = false

    objects = [{
      name                        = local.source_namespace
      backup_only_pvc             = false
      fail_backup_on_hook_failure = false
      exclude_params              = null
      include_params              = null
    }]
  }]

  recovery_mode                    = var.recovery_mode
  target_cluster_id                = local.target_cluster_id
  target_cluster_resource_group_id = module.resource_group.resource_group_id
  recoveries                       = []

  resource_tags = var.resource_tags
  access_tags   = var.access_tags
}

##############################################################################
# Target cluster — BRS backup & recovery module
#
# Reuses the same BRS instance created by module.source_backup_recovery.
# create_new_brs_instance = false tells the root module at plan time that no
# new BRS instance should be provisioned even though the source CRN is
# post-apply unknown when var.existing_brs_instance_crn is null.
#
# create_brs_vpe = true → VPEG created in the target VPC (separate from the
#                         source VPE) so target DSC traffic also stays private.
##############################################################################

module "target_backup_recovery" {
  source = "../.."
  providers = {
    ibm         = ibm
    ibm.cluster = ibm
    helm        = helm.target
    kubernetes  = kubernetes.target
  }

  # ---- Cluster ----
  cluster_id                   = local.target_cluster_id
  cluster_resource_group_id    = module.resource_group.resource_group_id
  cluster_config_endpoint_type = var.cluster_config_endpoint_type
  add_dsc_rules_to_cluster_sg  = false
  kube_type                    = "kubernetes"
  connection_env_type          = "kIksVpc"
  ibmcloud_api_key             = var.ibmcloud_api_key
  region                       = var.region
  dsc_storage_class            = "ibmc-vpc-block-metro-5iops-tier"
  dsc_worker_pool_zones        = 1
  enable_auto_protect          = false

  # ---- BRS instance (reuse source instance) ----
  # existing_brs_instance_crn references the source module output when no
  # pre-existing CRN is provided; create_new_brs_instance = false ensures
  # Terraform does not try to create a second instance at plan time.
  existing_brs_instance_crn = var.existing_brs_instance_crn != null ? var.existing_brs_instance_crn : module.source_backup_recovery.brs_instance_crn
  create_new_brs_instance   = false
  brs_connection_name       = var.target_connection_name != null ? var.target_connection_name : "${var.prefix}-target-connection"
  brs_create_new_connection = var.brs_create_new_connection
  brs_endpoint_type         = "public"

  # ---- VPE Gateway (target VPC) ----
  create_brs_vpe = true
  brs_vpe_name   = "${var.prefix}-target-vpe"
  vpc_id         = local.target_vpc_id
  vpc_subnets    = local.target_vpc_subnets

  # Target cluster is a recovery destination only — no policies or protection groups
  policies          = []
  protection_groups = []
  recoveries        = []

  resource_tags = var.resource_tags
  access_tags   = var.access_tags
}

##############################################################################
# Cross-cluster recovery (optional — enabled by var.enable_recovery)
##############################################################################

# Allow time for the target registration to propagate before polling backups
resource "time_sleep" "wait_for_target_registration" {
  count = var.enable_recovery ? 1 : 0

  depends_on      = [module.target_backup_recovery]
  create_duration = "30s"
}

# Poll for the first restorable backup run on the source protection group
resource "terraform_data" "wait_for_source_backup" {
  count = var.enable_recovery ? 1 : 0

  depends_on = [
    module.source_backup_recovery,
    time_sleep.wait_for_target_registration,
  ]

  input = {
    url                   = "https://${module.source_backup_recovery.brs_instance_guid}.${var.region}.backup-recovery.cloud.ibm.com"
    tenant                = module.source_backup_recovery.brs_tenant_id
    endpoint_type         = "public"
    instance_id           = module.source_backup_recovery.brs_instance_guid
    protection_group_id   = module.source_backup_recovery.protection_group_ids["${var.prefix}-source-pg"]
    api_key               = sensitive(var.ibmcloud_api_key)
    timeout_minutes       = 45
    poll_interval_seconds = 30
    binaries_path         = "/tmp"
  }

  provisioner "local-exec" {
    command     = "${path.module}/../../scripts/wait_for_backup_run.sh '${self.input.url}' '${self.input.tenant}' '${self.input.endpoint_type}' '${self.input.instance_id}' '${self.input.protection_group_id}' '${self.input.timeout_minutes}' '${self.input.poll_interval_seconds}' '${self.input.binaries_path}' > /tmp/backup_snapshot_${self.input.instance_id}.json"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
    }
  }
}

data "local_file" "snapshot_info" {
  count = var.enable_recovery ? 1 : 0

  filename   = "/tmp/backup_snapshot_${module.source_backup_recovery.brs_instance_guid}.json"
  depends_on = [terraform_data.wait_for_source_backup]
}

# Trigger the cross-cluster restore via the BRS API
resource "terraform_data" "cross_cluster_recovery" {
  count = var.enable_recovery ? 1 : 0

  input = {
    url              = "https://${module.source_backup_recovery.brs_instance_guid}.${var.region}.backup-recovery.cloud.ibm.com"
    tenant           = module.source_backup_recovery.brs_tenant_id
    endpoint_type    = "public"
    instance_id      = module.source_backup_recovery.brs_instance_guid
    source_pg_id     = split("::", module.source_backup_recovery.protection_group_ids["${var.prefix}-source-pg"])[1]
    target_source_id = split("::", module.target_backup_recovery.source_registration_id)[1]
    snapshot_id      = local.snapshot_data.snapshot_id
    api_key          = sensitive(var.ibmcloud_api_key)
    recovery_name    = "${var.prefix}-restore-to-target"
    namespace_prefix = "restored-"
    binaries_path    = "/tmp"
  }

  provisioner "local-exec" {
    command     = <<-EOT
      ${path.module}/../../scripts/trigger_cross_cluster_recovery.sh \
        '${self.input.url}' \
        '${self.input.tenant}' \
        '${self.input.endpoint_type}' \
        '${self.input.instance_id}' \
        '${self.input.source_pg_id}' \
        '${self.input.target_source_id}' \
        '${self.input.snapshot_id}' \
        '${self.input.recovery_name}' \
        '${self.input.namespace_prefix}' \
        '${self.input.binaries_path}'
    EOT
    interpreter = ["/bin/bash", "-c"]
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
    }
  }

  depends_on = [
    module.source_backup_recovery,
    module.target_backup_recovery,
    terraform_data.wait_for_source_backup,
  ]
}
