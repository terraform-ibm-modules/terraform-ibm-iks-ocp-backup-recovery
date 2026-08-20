##############################################################################
# Locals — Execution Stage & Phase Control
##############################################################################

locals {
  # Resolved execution flags based on execution_stage profile
  stage_cluster_infra_prep  = var.execution_stage == "all" || var.execution_stage == "cluster_prep" ? true : (var.execution_stage == "custom" ? var.enable_cluster_infra_prep : false)
  stage_dsc_helm_deployment = var.execution_stage == "all" || var.execution_stage == "cluster_prep" ? true : (var.execution_stage == "custom" ? var.enable_dsc_helm_deployment : false)
  stage_brs_registration    = var.execution_stage == "all" || var.execution_stage == "brs_management" ? true : (var.execution_stage == "custom" ? var.enable_brs_registration : false)
  stage_protection_groups   = var.execution_stage == "all" || var.execution_stage == "brs_management" ? true : (var.execution_stage == "custom" ? var.enable_protection_groups : false)
  stage_backup_and_recovery = var.execution_stage == "all" || var.execution_stage == "brs_management" ? true : (var.execution_stage == "custom" ? var.enable_backup_and_recovery : false)
}


##############################################################################
# Locals — Environment & Cluster
##############################################################################

locals {
  # Environment type detection — derived from connection_env_type suffix.
  is_vpc     = length(regexall("Vpc$", var.connection_env_type)) > 0
  is_classic = length(regexall("Classic$", var.connection_env_type)) > 0

  # Deployment mode flag.
  # DSC, source registration, and protection groups are always deployed in every
  # deployment_mode. deploy_recovery is the only mode-gated flag.
  deploy_recovery = var.deployment_mode == "full_backup_recovery"

  # Cluster attributes — resolved from the VPC or Classic data source, or from
  # caller-supplied overrides (used in cross-account brs_management invocations
  # where the provider cannot reach the source cluster).
  cluster_crn                  = var.cluster_crn != null ? var.cluster_crn : (local.is_vpc ? try(data.ibm_container_vpc_cluster.vpc_cluster[0].crn, null) : try(data.ibm_container_cluster.classic_cluster[0].crn, null))
  cluster_private_endpoint_url = local.is_vpc ? try(data.ibm_container_vpc_cluster.vpc_cluster[0].private_service_endpoint_url, null) : try(data.ibm_container_cluster.classic_cluster[0].private_service_endpoint_url, null)
  cluster_public_endpoint_url  = local.is_vpc ? try(data.ibm_container_vpc_cluster.vpc_cluster[0].public_service_endpoint_url, null) : try(data.ibm_container_cluster.classic_cluster[0].public_service_endpoint_url, null)
  cluster_private_available    = local.is_vpc ? try(data.ibm_container_vpc_cluster.vpc_cluster[0].private_service_endpoint, false) : try(data.ibm_container_cluster.classic_cluster[0].private_service_endpoint, false)
  cluster_endpoint             = var.cluster_endpoint != null ? var.cluster_endpoint : (var.cluster_config_endpoint_type == "private" && local.cluster_private_available ? local.cluster_private_endpoint_url : local.cluster_public_endpoint_url)
  cluster_endpoint_port        = local.cluster_endpoint != null ? element(split(":", local.cluster_endpoint), -1) : ""
}

##############################################################################
# Locals — DSC Configuration
##############################################################################

locals {
  # Helm chart URI parsing — splits the OCI URI into its chart name, version,
  # and registry location components used by the helm_release resource.
  uri_no_digest      = split("@", var.dsc_chart_uri)[0]
  chart_with_version = element(split("/", local.uri_no_digest), -1)
  dsc_chart          = split(":", local.chart_with_version)[0]
  dsc_chart_version  = replace(local.chart_with_version, "${local.dsc_chart}:", "")
  dsc_chart_location = replace(local.uri_no_digest, "/${local.chart_with_version}", "")

  # Resolved storage class for the DSC PVC — used in both the Helm values and
  # the diagnostics script so the expression is not repeated.
  dsc_storage_class = var.dsc_storage_class != null ? var.dsc_storage_class : (local.is_vpc ? "ibmc-vpc-block-metro-5iops-tier" : "ibmc-block-silver")

  # DSC worker pool zone math — calculates workers per zone based on total replicas.
  num_zones     = local.is_vpc && var.create_dsc_worker_pool ? var.dsc_worker_pool_zones : 0
  zones_list    = local.is_vpc && var.create_dsc_worker_pool ? try([for zone in data.ibm_container_vpc_worker_pool.pool[0].zones : zone], []) : []
  base_workers  = local.num_zones > 0 ? floor(var.dsc_replicas / local.num_zones) : 0
  extra_workers = local.num_zones > 0 ? var.dsc_replicas % local.num_zones : 0

  binaries_path = "/tmp"
}

##############################################################################
# Locals — BRS Instance
#
# The BRS instance is owned by the caller (DA or example) and its resolved
# attributes are passed in as prerequisite variables.
##############################################################################

locals {
  brs_tenant_id       = var.brs_tenant_id
  connection_id       = var.brs_connection_id
  registration_token  = var.brs_registration_token
  brs_instance_guid   = var.brs_instance_guid
  brs_instance_region = var.brs_instance_crn != null ? element(split(":", var.brs_instance_crn), 5) : null

  backup_recovery_instance_public_url  = var.brs_instance_public_url
  backup_recovery_instance_private_url = var.brs_instance_private_url

  # URL used by Terraform provider resources and scripts to reach the BRS API.
  backup_recovery_instance_url = var.brs_endpoint_type == "public" ? local.backup_recovery_instance_public_url : local.backup_recovery_instance_private_url

  # Resolved policy IDs passed in from the caller.
  resolved_policy_ids = var.resolved_policy_ids
}

resource "terraform_data" "install_dependencies" {
  count = var.install_required_binaries ? 1 : 0
  input = {
    binaries_path = local.binaries_path
  }
  provisioner "local-exec" {
    command     = "${path.module}/scripts/install-binaries.sh ${self.input.binaries_path}"
    interpreter = ["/bin/bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "${path.module}/scripts/install-binaries.sh ${self.input.binaries_path}"
    interpreter = ["/bin/bash", "-c"]
  }
}

##############################################################################
# Cluster Data Sources
##############################################################################

data "ibm_container_vpc_cluster" "vpc_cluster" {
  # Only query when cluster_prep is running — brs_management-only callers must
  # supply cluster_endpoint + cluster_crn directly to avoid cross-account 404s.
  count = local.stage_cluster_infra_prep && local.is_vpc ? 1 : 0

  name              = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}

data "ibm_container_cluster" "classic_cluster" {
  # Only query when cluster_prep is running — brs_management-only callers must
  # supply cluster_endpoint + cluster_crn directly to avoid cross-account 404s.
  count = local.stage_cluster_infra_prep && local.is_classic ? 1 : 0

  name              = var.cluster_id
  resource_group_id = var.cluster_resource_group_id
  wait_till         = var.wait_till
  wait_till_timeout = var.wait_till_timeout
}

data "ibm_container_cluster_config" "cluster_config" {
  count = local.stage_cluster_infra_prep || local.stage_dsc_helm_deployment ? 1 : 0

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

data "ibm_container_vpc_worker_pool" "pool" {
  count = local.stage_cluster_infra_prep && local.is_vpc ? 1 : 0

  cluster          = data.ibm_container_vpc_cluster.vpc_cluster[0].id
  worker_pool_name = data.ibm_container_vpc_cluster.vpc_cluster[0].worker_pools[0].name
}

##############################################################################
# Security Group Rules for Data Source Connector
##############################################################################

module "dsc_sg_rule" {
  count = local.stage_cluster_infra_prep && var.add_dsc_rules_to_cluster_sg && local.is_vpc ? 1 : 0

  source                       = "terraform-ibm-modules/security-group/ibm"
  version                      = "v2.9.1"
  resource_group               = var.cluster_resource_group_id
  existing_security_group_name = "kube-${var.cluster_id}"
  use_existing_security_group  = true
  security_group_rules = [
    {
      name      = "allow-outbound-443-from-cdsc-to-brs-dataplane"
      direction = "outbound"
      remote    = "0.0.0.0/0"
      protocol  = "tcp"
      port_min  = 443
      port_max  = 443
    },
    {
      name      = "allow-outbound-29991-from-cdsc-to-brs-dataplane"
      direction = "outbound"
      remote    = "0.0.0.0/0"
      protocol  = "tcp"
      port_min  = 29991
      port_max  = 29991
    },
    {
      name      = "allow-outbound-${local.cluster_endpoint_port}-from-cdsc-to-cluster-api"
      direction = "outbound"
      remote    = "0.0.0.0/0"
      protocol  = "tcp"
      port_min  = local.cluster_endpoint_port
      port_max  = local.cluster_endpoint_port
    }
  ]
}

##############################################################################
# Data Source Connector Worker Pools
##############################################################################

# VPC clusters — one pool per zone, spread dsc_replicas evenly across zones.
resource "ibm_container_vpc_worker_pool" "data_source_connector" {
  count = local.stage_cluster_infra_prep && local.is_vpc && var.create_dsc_worker_pool ? local.num_zones : 0

  cluster           = data.ibm_container_vpc_cluster.vpc_cluster[0].id
  worker_pool_name  = "dsc-pool-zone-${count.index + 1}"
  flavor            = var.dsc_worker_pool_flavor
  vpc_id            = data.ibm_container_vpc_worker_pool.pool[0].vpc_id
  worker_count      = count.index < local.extra_workers ? local.base_workers + 1 : local.base_workers
  resource_group_id = var.cluster_resource_group_id

  zones {
    name      = local.zones_list[count.index].name
    subnet_id = local.zones_list[count.index].subnet_id
  }

  labels = {
    "dedicated" = "data-source-connector"
  }

  taints {
    key    = "dedicated"
    value  = "data-source-connector"
    effect = "NoSchedule"
  }
}

# Classic clusters — a single pool sized to dsc_replicas; zone attachment is
# managed by the cluster itself so no zones block is needed here.
resource "ibm_container_worker_pool" "data_source_connector" {
  count = local.stage_cluster_infra_prep && local.is_classic && var.create_dsc_worker_pool ? 1 : 0

  cluster          = data.ibm_container_cluster.classic_cluster[0].id
  worker_pool_name = "dsc-pool"
  machine_type     = var.dsc_worker_pool_flavor
  size_per_zone    = var.dsc_replicas

  labels = {
    "dedicated" = "data-source-connector"
  }

  taints {
    key    = "dedicated"
    value  = "data-source-connector"
    effect = "NoSchedule"
  }
}

##############################################################################
# Wait for DSC Worker Pool Node(s) to be Ready
##############################################################################

# The IBM Cloud provider marks the worker pool as "created" as soon as the API
# confirms the pool exists, but the underlying VMs may not be in Kubernetes
# Ready state for several minutes after that. Scheduling the Helm release
# immediately causes the DSC pod to stay Pending until the node becomes Ready,
# which exhausts the Helm timeout (context deadline exceeded).
# This resource runs kubectl wait after pool creation to block the Helm install
# until at least one node with the "dedicated=data-source-connector" label is
# schedulable.  It is a no-op when create_dsc_worker_pool is false.
resource "terraform_data" "wait_for_dsc_node_ready" {
  count = local.stage_cluster_infra_prep && var.create_dsc_worker_pool && (local.is_vpc || local.is_classic) ? 1 : 0

  depends_on = [
    ibm_container_vpc_worker_pool.data_source_connector,
    ibm_container_worker_pool.data_source_connector,
  ]

  input = {
    kubeconfig_path = try(data.ibm_container_cluster_config.cluster_config[0].config_file_path, "")
  }

  provisioner "local-exec" {
    # Wait up to 15 minutes for at least one DSC node to become Ready.
    # --selector matches the label applied to every dsc-pool-zone-* worker pool.
    # `kubectl wait node --selector=...` fails immediately with "no matching resources
    # found" when zero nodes with that label exist yet (the VM is still provisioning).
    # So we first poll until at least one matching node appears, then wait for Ready.
    #
    # After the node reports Ready we sleep an additional 120 s. A node enters the
    # Ready condition as soon as its kubelet registers, but the scheduler's internal
    # cache and taint/toleration logic may not yet have accepted the node. Without
    # this extra delay the Helm install starts while the scheduler still considers
    # the node unschedulable, the DSC pod stays Pending for the entire Helm timeout,
    # and the install fails with "context deadline exceeded".
    command     = <<-EOT
      echo "Waiting for DSC node to appear (label dedicated=data-source-connector)..."
      for i in $(seq 1 90); do
        if kubectl get nodes --selector='dedicated=data-source-connector' --no-headers 2>/dev/null | grep -q .; then
          echo "Node found, waiting for Ready condition..."
          kubectl wait node --selector='dedicated=data-source-connector' --for=condition=Ready --timeout=900s || exit 1
          echo "Node is Ready. Sleeping 120 s to allow scheduler cache to sync..."
          sleep 120
          echo "Scheduler sync wait complete."
          exit 0
        fi
        echo "No DSC node yet, retry $i/90 (sleeping 10s)..."
        sleep 10
      done
      echo "Timed out waiting for DSC node to appear after 15 minutes"
      exit 1
    EOT
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = self.input.kubeconfig_path
    }
  }
}

##############################################################################
# Data Source Connector Namespace
##############################################################################

resource "kubernetes_namespace_v1" "dsc_namespace" {
  count = local.stage_dsc_helm_deployment ? 1 : 0

  metadata {
    name = var.dsc_namespace
  }

  timeouts {
    delete = "10m"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels
    ]
  }
}

##############################################################################
# Freeze immutable Helm values at first install
##############################################################################

# volumeClaimTemplate.storageClass is an immutable StatefulSet field —
# the Kubernetes API rejects any helm upgrade that changes it.
# Storing it in input under ignore_changes freezes the value at first apply
# so post-install changes to var.dsc_storage_class never reach helm upgrade.
# To change it: terraform destroy, clean up PVCs/PVs, then terraform apply.
resource "terraform_data" "dsc_immutable_values" {
  count = local.stage_dsc_helm_deployment ? 1 : 0

  input = {
    storage_class   = local.dsc_storage_class
    namespace       = kubernetes_namespace_v1.dsc_namespace[0].metadata[0].name
    kubeconfig_path = try(data.ibm_container_cluster_config.cluster_config[0].config_file_path, "")
    dsc_name        = var.dsc_name
  }

  lifecycle {
    ignore_changes = [input]
  }

  # On destroy: delete DSC PVCs after helm uninstall (helm_release depends_on
  # this resource, so it is destroyed first). RECLAIMPOLICY=Retain PVs are
  # printed for manual deletion; Delete-policy PVs are removed automatically.
  # on_failure = continue: PVC cleanup is best-effort — if the cluster or
  # namespace is already gone (e.g. force-deleted externally), a kubectl error
  # must not block the rest of `terraform destroy`.
  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = self.input.kubeconfig_path
    }
    command = "${path.module}/scripts/purge-stale-dsc-pvc.sh '${self.input.namespace}' '${self.input.dsc_name}' destroy"
  }

  depends_on = [kubernetes_namespace_v1.dsc_namespace]
}
##############################################################################
# Check for existing BRS agent namespaces (conflict detection)
##############################################################################

# If a brs-backup-agent-* namespace already exists on the cluster, it means
# the cluster is already registered to a BRS instance. We should not silently
# overwrite or re-attach the cluster to a new BRS instance, as this would
# fragment backup data across BRS instances and confuse customers.
# Exit early with a clear explanation of what the customer must do.
resource "terraform_data" "check_existing_registration" {
  count = local.stage_dsc_helm_deployment ? 1 : 0

  input = {
    kubeconfig_path = try(data.ibm_container_cluster_config.cluster_config[0].config_file_path, "")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = self.input.kubeconfig_path
    }
    command = "${path.module}/scripts/check-existing-registration.sh"
  }

  depends_on = [data.ibm_container_cluster_config.cluster_config]
}



##############################################################################
# Purge stale DSC PVCs before Helm install
##############################################################################

# Orphaned PVCs from a failed install hold stale gandalf state and an expired
# token; re-mounting them crashes the DSC immediately. The script deletes them
# only when no live pod exists — upgrades are safe. Destroy-time PVC cleanup
# is handled by dsc_immutable_values (destroyed after helm_release).
resource "terraform_data" "purge_stale_dsc_pvc" {
  count = local.stage_dsc_helm_deployment ? 1 : 0

  triggers_replace = {
    namespace          = kubernetes_namespace_v1.dsc_namespace[0].metadata[0].name
    registration_token = local.registration_token != null ? local.registration_token : ""
  }

  input = {
    namespace       = kubernetes_namespace_v1.dsc_namespace[0].metadata[0].name
    kubeconfig_path = try(data.ibm_container_cluster_config.cluster_config[0].config_file_path, "")
    dsc_name        = var.dsc_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = self.input.kubeconfig_path
    }
    command = "${path.module}/scripts/purge-stale-dsc-pvc.sh '${self.input.namespace}' '${self.input.dsc_name}'"
  }

  depends_on = [
    kubernetes_namespace_v1.dsc_namespace,
    terraform_data.check_existing_registration
  ]
}

##############################################################################
# Data Source Connector Helm Release
##############################################################################

resource "helm_release" "data_source_connector" {
  count = local.stage_dsc_helm_deployment ? 1 : 0

  name             = var.dsc_name
  chart            = local.dsc_chart
  repository       = local.dsc_chart_location
  namespace        = kubernetes_namespace_v1.dsc_namespace[0].metadata[0].name
  version          = local.dsc_chart_version
  create_namespace = false
  timeout          = var.dsc_helm_timeout
  wait             = true
  atomic           = false # DSC docs §8: rollbacks are unsupported and can corrupt PVC state.
  cleanup_on_fail  = true

  values = [
    yamlencode({
      secrets = {
        registrationToken = local.registration_token != null ? local.registration_token : ""
      }
      # image.tag is intentionally omitted — the chart uses its AppVersion as the
      # default tag, which is pinned to the chart version in dsc_chart_uri.
      # DSC docs §6.1: "image.tag need not be supplied during helm install/upgrade".
      replicaCount     = var.dsc_replicas
      fullnameOverride = var.dsc_name
      resources = {
        limits = {
          cpu    = var.dsc_pod_cpu_limits
          memory = var.dsc_pod_memory_limits
        }
        requests = {
          cpu    = var.dsc_pod_cpu_requests
          memory = var.dsc_pod_memory_requests
        }
      }
      nodeSelector = var.create_dsc_worker_pool ? {
        "dedicated" = "data-source-connector"
      } : {}
      tolerations = var.create_dsc_worker_pool ? [
        {
          key      = "dedicated"
          operator = "Equal"
          value    = "data-source-connector"
          effect   = "NoSchedule"
        }
      ] : []
      volumeClaimTemplate = {
        # Frozen at first apply — see dsc_immutable_values.
        storageClass = terraform_data.dsc_immutable_values[0].input.storage_class
      }
    })
  ]

  depends_on = [
    terraform_data.dsc_immutable_values,
    terraform_data.wait_for_dsc_node_ready,
    terraform_data.check_existing_registration,
    terraform_data.purge_stale_dsc_pvc,
    ibm_container_vpc_worker_pool.data_source_connector,
    ibm_container_worker_pool.data_source_connector,
    kubernetes_namespace_v1.dsc_namespace,
  ]

  lifecycle {
    precondition {
      condition = (
        var.kube_type == "kubernetes" ? contains(["kIksVpc", "kIksClassic"], var.connection_env_type) :
        var.kube_type == "openshift" ? contains(["kRoksVpc", "kRoksClassic"], var.connection_env_type) :
        false
      )
      error_message = "Invalid connection_env_type '${var.connection_env_type}' for kube_type '${var.kube_type}'. When kube_type is 'kubernetes', connection_env_type must be 'kIksVpc' or 'kIksClassic'. When kube_type is 'openshift', connection_env_type must be 'kRoksVpc' or 'kRoksClassic'."
    }
  }

  # Collect pod, event, PVC, and node diagnostics when the Helm install fails.
  # on_failure = continue ensures output is visible even when helm times out.
  provisioner "local-exec" {
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = try(data.ibm_container_cluster_config.cluster_config[0].config_file_path, "")
    }
    command = "${path.module}/scripts/dsc-helm-diagnostics.sh '${self.namespace}' '${local.dsc_storage_class}'"
  }
}

##############################################################################
# BRS Agent Service Account & RBAC
##############################################################################

# Ignore changes to image_pull_secret, secret, and annotations as they are
# updated by the cluster outside of terraform. This prevents terraform from
# recreating/updating the service account on every apply.
resource "kubernetes_service_account_v1" "brsagent" {
  count = local.stage_dsc_helm_deployment ? 1 : 0

  metadata {
    name      = "brsagent"
    namespace = var.dsc_namespace
  }

  lifecycle {
    ignore_changes = [
      image_pull_secret,
      secret,
      metadata[0].annotations,
    ]
  }
  depends_on = [kubernetes_namespace_v1.dsc_namespace]
}

resource "kubernetes_cluster_role_binding_v1" "brsagent_admin" {
  count = local.stage_dsc_helm_deployment ? 1 : 0

  metadata {
    name = "brsagent-admin"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.brsagent[0].metadata[0].name
    namespace = kubernetes_service_account_v1.brsagent[0].metadata[0].namespace
  }
}

resource "kubernetes_secret_v1" "brsagent_token" {
  count = local.stage_dsc_helm_deployment ? 1 : 0

  metadata {
    name      = "brsagent-token"
    namespace = kubernetes_service_account_v1.brsagent[0].metadata[0].namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.brsagent[0].metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

##############################################################################
# Source Registration
##############################################################################

# Wait for DSC to stabilize after helm installation before source registration.
resource "time_sleep" "wait_for_dsc_stabilization" {
  count      = local.stage_dsc_helm_deployment ? 1 : 0
  depends_on = [helm_release.data_source_connector]

  # 10m observed minimum for the DSC gRPC tunnel to BRS to fully establish after
  # the pod passes Kubernetes readiness (/bifrost/readyz). The readiness probe only
  # confirms the HTTP server started — the BRS cluster-config protobin handshake
  # and reverse-tunnel setup take several additional minutes. Without this wait,
  # source_registration hits the BRS API before the DSC has connected, causing
  # RegisterProtectionSourceWithContext: Gateway Timeout (BRS internal 9-10 min limit).
  create_duration = "10m"
}

# On destroy this sends DELETE to BRS, permanently removing the connector identity.
# Correct for a full terraform destroy (PVCs also deleted).
# NOT correct for a temporary scale-down (kubectl scale ... --replicas=0): pods
# retain their identity and reconnect automatically when scaled back up — do not
# deregister. Because terraform destroy always deletes PVCs too, the destroy path
# here is always safe.
resource "ibm_backup_recovery_source_registration" "source_registration" {
  count = local.stage_brs_registration ? 1 : 0

  x_ibm_tenant_id = local.brs_tenant_id
  environment     = "kKubernetes"
  connection_id   = local.connection_id
  endpoint_type   = var.brs_endpoint_type
  instance_id     = local.brs_instance_guid
  region          = local.brs_instance_region

  kubernetes_params {
    endpoint                = local.cluster_endpoint
    kubernetes_distribution = var.kube_type == "openshift" ? "kROKS" : "kIKS"
    dynamic "auto_protect_config" {
      for_each = var.enable_auto_protect && var.auto_protect_policy_name != null && try(local.resolved_policy_ids[var.auto_protect_policy_name], null) != null ? [1] : []
      content {
        is_default_auto_protected = true
        policy_id                 = local.resolved_policy_ids[var.auto_protect_policy_name]
      }
    }
    data_mover_image_location                  = var.registration_images.data_mover
    velero_image_location                      = var.registration_images.velero
    velero_aws_plugin_image_location           = var.registration_images.velero_aws_plugin
    velero_openshift_plugin_image_location     = var.registration_images.velero_openshift_plugin
    init_container_image_location              = var.registration_images.init_container
    cohesity_dataprotect_plugin_image_location = var.registration_images.cohesity_dataprotect_plugin
    kubernetes_type                            = "kCluster"
    client_private_key                         = try(chomp(kubernetes_secret_v1.brsagent_token[0].data["token"]), chomp(var.brsagent_token), "")
  }

  depends_on = [
    helm_release.data_source_connector,
    time_sleep.wait_for_dsc_stabilization,
    # BRS removes the brs-backup-agent-* namespace asynchronously after this
    # DELETE, via the DSC tunnel and the brsagent RBAC, so both must outlive it.
    # Depending on the waiter (rather than the reverse) is what destroys it after
    # us. Never reference this resource from either waiter: that inverts the edge,
    # runs them before the DELETE, and orphans the namespace.
    terraform_data.wait_before_helm_destroy,
  ]

  # service_name is an undocumented, provider-computed attribute. The provider
  # applies a default ("backup-recovery") at plan time but stores null in state,
  # so every re-plan shows a null -> "backup-recovery" diff. Because the field is
  # ForceNew, that spurious diff forces a full replacement on each apply (and
  # fails the post-apply consistency check). Ignore it so registration stays
  # stable.
  lifecycle {
    ignore_changes = [service_name]
  }
}

# Poll until BRS confirms the source registration is gone, before the data source
# connection is deleted — deleting a connection a source still references fails
# with "can't be deleted as it is being used by the source". Runs after the DELETE
# and before the helm release / brsagent RBAC are torn down.
#
# Identified by connection ID + cluster endpoint, never by source_id: referencing
# the registration resource inverts the destroy edge and runs this poller before
# the DELETE it is waiting on.
resource "terraform_data" "brs_source_deregistration_wait" {
  count = local.stage_brs_registration ? 1 : 0

  depends_on = [
    helm_release.data_source_connector,
    kubernetes_cluster_role_binding_v1.brsagent_admin,
    kubernetes_secret_v1.brsagent_token,
  ]

  input = {
    region           = local.brs_instance_region
    tenant_id        = local.brs_tenant_id
    brs_endpoint     = local.backup_recovery_instance_public_url
    connection_id    = tostring(local.connection_id)
    cluster_endpoint = local.cluster_endpoint
    ibmcloud_api_key = sensitive(var.ibmcloud_api_key) # pragma: allowlist secret
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    # Signature: REGION TENANT BRS_ENDPOINT CONNECTION_ID CLUSTER_ENDPOINT [TIMEOUT_S] [POLL_S]
    # Exits 0 on timeout so destroy always proceeds.
    command = "${path.module}/scripts/wait-for-deregistration.sh '${try(self.input.region, "")}' '${try(self.input.tenant_id, "")}' '${try(self.input.brs_endpoint, "")}' '${try(self.input.connection_id, "")}' '${try(self.input.cluster_endpoint, "")}' 600 20"
    environment = {
      IBMCLOUD_API_KEY = self.input.ibmcloud_api_key # pragma: allowlist secret
    }
  }
}

# Destroy-time gate: keeps the DSC pod and the brsagent SA/CRB/token alive until
# BRS has finished removing the brs-backup-agent-* namespace. source_registration
# depends on this, so it runs after the DELETE; helm_release and the brsagent RBAC
# depend on it, so they are torn down only once it returns.
resource "terraform_data" "wait_before_helm_destroy" {
  count = local.stage_brs_registration ? 1 : 0

  depends_on = [
    helm_release.data_source_connector,
    kubernetes_cluster_role_binding_v1.brsagent_admin,
    kubernetes_secret_v1.brsagent_token,
  ]

  # This resource exists solely to run a destroy-time provisioner (namespace
  # cleanup) before the helm release is destroyed; it has no create/update
  # behavior, so it never needs to be replaced. Values needed by the destroy
  # provisioner are stored in input (available via self.input at destroy time).
  # No triggers_replace: a helm release update (e.g. the by-design registration
  # token rotation) would make helm_release.id "known after apply" and cascade
  # into a spurious replacement. An input change is only ever an in-place update
  # that runs no provisioner, so it is side-effect free.
  input = {
    kubeconfig_path = try(data.ibm_container_cluster_config.cluster_config[0].config_file_path, "")
    dsc_namespace   = var.dsc_namespace
    binaries_path   = local.binaries_path
  }

  # self.input is wrapped in try() so the destroy provisioner stays safe when the
  # resource instance was created by an older module version that stored these
  # values in triggers_replace instead of input (in that case self.input is null
  # in state). An empty KUBECONFIG makes the script report that it cannot check
  # the cluster and exit cleanly, which is the correct behaviour during that
  # one-time migration.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    # Signature: DSC_NAMESPACE [MAX_ATTEMPTS] [BINARIES_PATH]. 30 x 30s = 15 min.
    # Always exits 0 — an unreachable cluster must not block destroy — but says so.
    command = "${path.module}/scripts/wait_for_namespace_cleanup.sh '${try(self.input.dsc_namespace, "ibm-brs-data-source-connector")}' 30 '${try(self.input.binaries_path, "/tmp")}'"
    environment = {
      KUBECONFIG = try(self.input.kubeconfig_path, "")
    }
  }
}

# Poll the BRS protection-sources API until the DSC initial discovery pass is
# complete — i.e., until the registered cluster appears as a source node with
# at least one child object (namespace or PVC).  This replaces the old blind
# time_sleep which was either too short (sources empty) or wasteful (waited
# long after discovery had already finished).
#
# The script calls `ibmcloud backup-recovery protection-source list` every 30 s
# and exits 0 as soon as children are visible, or exits 1 after a configurable
# timeout (default 30 min).  Terraform will surface the timeout as a clear
# error rather than a silent precondition failure.
resource "terraform_data" "wait_for_source_discovery" {
  count = local.stage_brs_registration ? 1 : 0

  depends_on = [
    ibm_backup_recovery_source_registration.source_registration,
    helm_release.data_source_connector,
    terraform_data.install_dependencies
  ]

  triggers_replace = {
    connection_id = local.connection_id
    dsc_version   = var.dsc_chart_uri
    source_id     = try(tostring(ibm_backup_recovery_source_registration.source_registration[0].source_id), "")
  }

  input = {
    region          = local.brs_instance_region
    tenant_id       = local.brs_tenant_id
    registration_id = try(tostring(ibm_backup_recovery_source_registration.source_registration[0].source_id), "")
    brs_endpoint    = local.backup_recovery_instance_public_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # Script signature: REGION TENANT REGISTRATION_ID BRS_ENDPOINT [TIMEOUT_S] [POLL_S]
    command = "${path.module}/scripts/wait-for-source-discovery.sh '${self.input.region}' '${self.input.tenant_id}' '${self.input.registration_id}' '${self.input.brs_endpoint}'"
    environment = {
      IBMCLOUD_API_KEY = var.ibmcloud_api_key # pragma: allowlist secret
    }
  }
}

data "ibm_backup_recovery_protection_sources" "sources" {
  count           = local.stage_brs_registration || local.stage_protection_groups ? 1 : 0
  x_ibm_tenant_id = local.brs_tenant_id
  environment     = "kKubernetes"
  instance_id     = local.brs_instance_guid
  region          = local.brs_instance_region
  endpoint_type   = var.brs_endpoint_type

  depends_on = [terraform_data.wait_for_source_discovery]
}

##############################################################################
# Locals — Protection Source Tree
#
# Flatten the kKubernetes source tree returned by the BRS protection-sources
# API into a flat name→ID map used to resolve protection group object names
# (namespaces, PVCs, etc.) to the numeric IDs that the BRS API requires.
#
# The tree has three levels inside each environment envelope:
#
#   protection_sources[N]          ← env envelope (no protection_source attr)
#     └── nodes[M]                 ← cluster node
#           IKS:  protection_source[0].id = cluster source_id
#           OCP:  NO protection_source attr at this level
#           └── nodes[K]           ← namespace / label nodes
#                 IKS:  protection_source[0].id = namespace object id
#                 OCP:  protection_source[0].id = namespace object id
#                       protection_source[0].parent_id = cluster source_id
#                 └── nodes[J]     ← workload nodes (PVCs, pods, etc.)
#
# When source_id is not yet known or not found in the tree (source discovery
# still in progress), the cluster filter is skipped so all nodes are included —
# this avoids an empty all_flat_objects and prevents a spurious precondition
# failure while the DSC is still doing its initial discovery pass.
##############################################################################

locals {
  # The registered source_id as a string — used for tree-filtering comparisons.
  source_id_str = try(tostring(ibm_backup_recovery_source_registration.source_registration[0].source_id), "")

  # All top-level environment entries returned by the BRS protection-sources API,
  # with a null guard so the expression is safe before the data source is populated.
  raw_envs = try(data.ibm_backup_recovery_protection_sources.sources[0].protection_sources, []) != null ? try(data.ibm_backup_recovery_protection_sources.sources[0].protection_sources, []) : []

  # IKS clusters: the registered source_id equals protection_source[0].id on the
  # cluster node. Build a set of all such IDs so we can cheaply detect IKS mode.
  known_cluster_node_ids = toset(flatten([
    for env in local.raw_envs : [
      for cluster_node in(env.nodes != null ? env.nodes : []) :
      tostring(cluster_node.protection_source[0].id)
      if cluster_node.protection_source != null && length(cluster_node.protection_source) > 0
    ]
  ]))

  # OCP clusters: the registered source_id appears as protection_source[0].parent_id
  # on namespace nodes. Build a set of all such parent IDs so we can detect OCP mode.
  known_namespace_parent_ids = toset(flatten([
    for env in local.raw_envs : [
      for cluster_node in(env.nodes != null ? env.nodes : []) : [
        for namespace_node in(cluster_node.nodes != null ? cluster_node.nodes : []) :
        tostring(try(namespace_node.protection_source[0].parent_id, ""))
        if namespace_node.protection_source != null && length(namespace_node.protection_source) > 0 &&
        try(namespace_node.protection_source[0].parent_id, null) != null
      ]
    ]
  ]))

  # Whether to scope the tree walk to a single registered cluster.
  # Skipped when source_id is not yet known or not found in the tree.
  should_filter_by_registered_cluster = (
    try(ibm_backup_recovery_source_registration.source_registration[0].source_id, null) != null &&
    (
      contains(local.known_cluster_node_ids, local.source_id_str) ||
      contains(local.known_namespace_parent_ids, local.source_id_str)
    )
  )

  # Cluster-level nodes — one per registered cluster within each environment.
  # When filtering is active, only the node matching the registered cluster is kept.
  #   IKS: match by cluster_node.protection_source[0].id == source_id
  #   OCP: match by any namespace child having protection_source[0].parent_id == source_id
  cluster_nodes = flatten([
    for env in local.raw_envs : [
      for cluster_node in(env.nodes != null ? env.nodes : []) : cluster_node
      if !local.should_filter_by_registered_cluster ||
      # IKS path — source_id is the cluster node's own object ID
      (cluster_node.protection_source != null &&
        length(cluster_node.protection_source) > 0 &&
      tostring(cluster_node.protection_source[0].id) == local.source_id_str) ||
      # OCP path — source_id appears as parent_id on one of the cluster's namespace children
      anytrue([
        for namespace_node in(cluster_node.nodes != null ? cluster_node.nodes : []) :
        (namespace_node.protection_source != null &&
          length(namespace_node.protection_source) > 0 &&
        tostring(try(namespace_node.protection_source[0].parent_id, "")) == local.source_id_str)
      ])
    ]
  ])

  # protection_source entries on cluster-level nodes (the cluster objects themselves).
  cluster_protection_sources = flatten([
    for cluster_node in local.cluster_nodes : [
      for ps in(cluster_node.protection_source != null ? cluster_node.protection_source : []) : {
        id   = ps.id
        name = ps.name
      }
    ]
  ])

  # Namespace-level nodes — direct children of each cluster node.
  namespace_nodes = flatten([
    for cluster_node in local.cluster_nodes :
    (cluster_node.nodes != null ? cluster_node.nodes : [])
  ])

  # protection_source entries on namespace nodes (namespace / project objects).
  namespace_protection_sources = flatten([
    for namespace_node in local.namespace_nodes : [
      for ps in(namespace_node.protection_source != null ? namespace_node.protection_source : []) : {
        id   = ps.id
        name = ps.name
      }
    ]
  ])

  # Workload-level nodes — direct children of each namespace node (PVCs, pods, etc.).
  workload_nodes = flatten([
    for namespace_node in local.namespace_nodes :
    (namespace_node.nodes != null ? namespace_node.nodes : [])
  ])

  # protection_source entries on workload nodes (individual PVC / workload objects).
  workload_protection_sources = flatten([
    for workload_node in local.workload_nodes : [
      for ps in(workload_node.protection_source != null ? workload_node.protection_source : []) : {
        id   = ps.id
        name = ps.name
      }
    ]
  ])

  # Flat list of every discoverable object across all three levels, indexed by name.
  # The grouping operator (...) keeps duplicate names as a list so the map never
  # errors when the same name appears at more than one level.
  all_flat_objects  = concat(local.cluster_protection_sources, local.namespace_protection_sources, local.workload_protection_sources)
  object_name_to_id = { for obj in local.all_flat_objects : obj.name => obj.id... }
}

##############################################################################
# Protection Groups (granular backup control)
##############################################################################

resource "ibm_backup_recovery_protection_group" "protection_group" {
  for_each = local.stage_protection_groups ? { for pg in var.protection_groups : pg.name => pg } : {}

  x_ibm_tenant_id    = local.brs_tenant_id
  name               = each.value.name
  environment        = "kKubernetes"
  policy_id          = local.resolved_policy_ids[each.value.policy_name]
  description        = each.value.description
  is_paused          = each.value.is_paused
  abort_in_blackouts = each.value.abort_in_blackouts
  pause_in_blackouts = each.value.pause_in_blackouts
  priority           = each.value.priority
  qos_policy         = each.value.qos_policy
  endpoint_type      = var.brs_endpoint_type
  instance_id        = local.brs_instance_guid
  region             = local.brs_instance_region
  delete_snapshots   = each.value.delete_snapshots

  kubernetes_params {
    enable_indexing       = each.value.enable_indexing
    leverage_csi_snapshot = each.value.leverage_csi_snapshot
    non_snapshot_backup   = each.value.non_snapshot_backup
    volume_backup_failure = each.value.volume_backup_failure
    exclude_object_ids    = each.value.exclude_object_ids != null ? each.value.exclude_object_ids : []
    label_ids             = each.value.label_ids != null ? each.value.label_ids : []
    exclude_label_ids     = each.value.exclude_label_ids != null ? each.value.exclude_label_ids : []

    dynamic "objects" {
      for_each = each.value.objects != null ? each.value.objects : []
      content {
        id                          = objects.value.id != null ? objects.value.id : try(local.object_name_to_id[objects.value.name][0], null)
        backup_only_pvc             = objects.value.backup_only_pvc
        fail_backup_on_hook_failure = objects.value.fail_backup_on_hook_failure
        included_resources          = objects.value.included_resources
        excluded_resources          = objects.value.excluded_resources

        dynamic "include_pvcs" {
          for_each = objects.value.include_pvcs != null ? objects.value.include_pvcs : []
          content {
            id   = include_pvcs.value.id != null ? include_pvcs.value.id : try(local.object_name_to_id[include_pvcs.value.name][0], null)
            name = include_pvcs.value.name
          }
        }

        dynamic "exclude_pvcs" {
          for_each = objects.value.exclude_pvcs != null ? objects.value.exclude_pvcs : []
          content {
            id   = exclude_pvcs.value.id != null ? exclude_pvcs.value.id : try(local.object_name_to_id[exclude_pvcs.value.name][0], null)
            name = exclude_pvcs.value.name
          }
        }

        dynamic "include_params" {
          for_each = objects.value.include_params != null ? [objects.value.include_params] : []
          content {
            label_combination_method = include_params.value.label_combination_method

            dynamic "label_vector" {
              for_each = include_params.value.label_vector != null ? include_params.value.label_vector : []
              content {
                key   = label_vector.value.key
                value = label_vector.value.value
              }
            }

            dynamic "selected_resources" {
              for_each = include_params.value.selected_resources != null ? include_params.value.selected_resources : []
              content {
                api_group         = selected_resources.value.api_group
                is_cluster_scoped = selected_resources.value.is_cluster_scoped
                kind              = selected_resources.value.kind
                name              = selected_resources.value.name
                version           = selected_resources.value.version

                dynamic "resource_list" {
                  for_each = selected_resources.value.resource_list != null ? selected_resources.value.resource_list : []
                  content {
                    entity_id = resource_list.value.entity_id
                    name      = resource_list.value.name
                  }
                }
              }
            }
          }
        }

        dynamic "exclude_params" {
          for_each = objects.value.exclude_params != null ? [objects.value.exclude_params] : []
          content {
            label_combination_method = exclude_params.value.label_combination_method

            dynamic "label_vector" {
              for_each = exclude_params.value.label_vector != null ? exclude_params.value.label_vector : []
              content {
                key   = label_vector.value.key
                value = label_vector.value.value
              }
            }

            dynamic "selected_resources" {
              for_each = exclude_params.value.selected_resources != null ? exclude_params.value.selected_resources : []
              content {
                api_group         = selected_resources.value.api_group
                is_cluster_scoped = selected_resources.value.is_cluster_scoped
                kind              = selected_resources.value.kind
                name              = selected_resources.value.name
                version           = selected_resources.value.version

                dynamic "resource_list" {
                  for_each = selected_resources.value.resource_list != null ? selected_resources.value.resource_list : []
                  content {
                    entity_id = resource_list.value.entity_id
                    name      = resource_list.value.name
                  }
                }
              }
            }
          }
        }

        dynamic "quiesce_groups" {
          for_each = objects.value.quiesce_groups != null ? objects.value.quiesce_groups : []
          content {
            quiesce_mode = quiesce_groups.value.quiesce_mode

            dynamic "quiesce_rules" {
              for_each = quiesce_groups.value.quiesce_rules
              content {
                dynamic "pod_selector_labels" {
                  for_each = quiesce_rules.value.pod_selector_labels != null ? quiesce_rules.value.pod_selector_labels : []
                  content {
                    key   = pod_selector_labels.value.key
                    value = pod_selector_labels.value.value
                  }
                }

                dynamic "pre_snapshot_hooks" {
                  for_each = quiesce_rules.value.pre_snapshot_hooks
                  content {
                    commands      = pre_snapshot_hooks.value.commands
                    container     = pre_snapshot_hooks.value.container
                    fail_on_error = pre_snapshot_hooks.value.fail_on_error
                    timeout       = pre_snapshot_hooks.value.timeout
                  }
                }

                dynamic "post_snapshot_hooks" {
                  for_each = quiesce_rules.value.post_snapshot_hooks
                  content {
                    commands      = post_snapshot_hooks.value.commands
                    container     = post_snapshot_hooks.value.container
                    fail_on_error = post_snapshot_hooks.value.fail_on_error
                    timeout       = post_snapshot_hooks.value.timeout
                  }
                }
              }
            }
          }
        }
      }
    }

    # Global label-based inclusion filter
    dynamic "include_params" {
      for_each = each.value.include_params != null ? [each.value.include_params] : []
      content {
        label_combination_method = include_params.value.label_combination_method

        dynamic "label_vector" {
          for_each = include_params.value.label_vector != null ? include_params.value.label_vector : []
          content {
            key   = label_vector.value.key
            value = label_vector.value.value
          }
        }

        dynamic "selected_resources" {
          for_each = include_params.value.selected_resources != null ? include_params.value.selected_resources : []
          content {
            api_group         = selected_resources.value.api_group
            is_cluster_scoped = selected_resources.value.is_cluster_scoped
            kind              = selected_resources.value.kind
            name              = selected_resources.value.name
            version           = selected_resources.value.version

            dynamic "resource_list" {
              for_each = selected_resources.value.resource_list != null ? selected_resources.value.resource_list : []
              content {
                entity_id = resource_list.value.entity_id
                name      = resource_list.value.name
              }
            }
          }
        }
      }
    }

    # Global label-based exclusion filter
    dynamic "exclude_params" {
      for_each = each.value.exclude_params != null ? [each.value.exclude_params] : []
      content {
        label_combination_method = exclude_params.value.label_combination_method

        dynamic "label_vector" {
          for_each = exclude_params.value.label_vector != null ? exclude_params.value.label_vector : []
          content {
            key   = label_vector.value.key
            value = label_vector.value.value
          }
        }

        dynamic "selected_resources" {
          for_each = exclude_params.value.selected_resources != null ? exclude_params.value.selected_resources : []
          content {
            api_group         = selected_resources.value.api_group
            is_cluster_scoped = selected_resources.value.is_cluster_scoped
            kind              = selected_resources.value.kind
            name              = selected_resources.value.name
            version           = selected_resources.value.version

            dynamic "resource_list" {
              for_each = selected_resources.value.resource_list != null ? selected_resources.value.resource_list : []
              content {
                entity_id = resource_list.value.entity_id
                name      = resource_list.value.name
              }
            }
          }
        }
      }
    }
  }

  dynamic "alert_policy" {
    for_each = each.value.alert_policy != null ? [each.value.alert_policy] : []
    content {
      backup_run_status                                   = alert_policy.value.backup_run_status
      raise_object_level_failure_alert                    = alert_policy.value.raise_object_level_failure_alert
      raise_object_level_failure_alert_after_each_attempt = alert_policy.value.raise_object_level_failure_alert_after_each_attempt
      raise_object_level_failure_alert_after_last_attempt = alert_policy.value.raise_object_level_failure_alert_after_last_attempt

      dynamic "alert_targets" {
        for_each = alert_policy.value.alert_targets != null ? alert_policy.value.alert_targets : []
        content {
          email_address  = alert_targets.value.email_address
          language       = alert_targets.value.language
          recipient_type = alert_targets.value.recipient_type
        }
      }
    }
  }

  dynamic "sla" {
    for_each = each.value.sla != null ? each.value.sla : []
    content {
      backup_run_type = sla.value.backup_run_type
      sla_minutes     = sla.value.sla_minutes
    }
  }

  dynamic "start_time" {
    for_each = each.value.start_time != null ? [each.value.start_time] : []
    content {
      hour      = start_time.value.hour
      minute    = start_time.value.minute
      time_zone = start_time.value.time_zone
    }
  }

  dynamic "advanced_configs" {
    for_each = each.value.advanced_configs != null ? each.value.advanced_configs : []
    content {
      key   = advanced_configs.value.key
      value = advanced_configs.value.value
    }
  }

  depends_on = [
    data.ibm_backup_recovery_protection_sources.sources,
    terraform_data.wait_for_source_discovery
  ]

  lifecycle {
    precondition {
      condition     = length(local.all_flat_objects) > 0
      error_message = <<-EOT
        Protection sources are empty. The Data Source Connector may not have completed
        its initial discovery yet. Wait a few minutes and run 'terraform apply' again.
      EOT
    }

    # Ignore changes to include_params within objects when it's returned as empty by the API
    # This prevents perpetual drift when include_params is not explicitly set in the configuration
    ignore_changes = [
      kubernetes_params[0].objects[0].include_params
    ]
  }
}

##############################################################################
# Cancel running backup jobs before protection group deletion
##############################################################################

# Cancels any active backup run on each protection group during destroy.
# Must depend on the protection group so Terraform destroys this resource first,
# running the cancel provisioner before the provider attempts to delete the group.
resource "terraform_data" "cancel_pg_runs" {
  for_each = local.stage_protection_groups ? { for pg in var.protection_groups : pg.name => pg } : {}

  input = {
    region              = local.brs_instance_region
    tenant              = local.brs_tenant_id
    brs_endpoint        = local.backup_recovery_instance_url
    protection_group_id = ibm_backup_recovery_protection_group.protection_group[each.key].id
  }

  triggers_replace = {
    api_key = sensitive(var.ibmcloud_api_key)
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "${path.module}/scripts/cancel_pg_runs.sh '${self.input.region}' '${self.input.tenant}' '${self.input.protection_group_id}' '${self.input.brs_endpoint}'"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      IBMCLOUD_API_KEY = self.triggers_replace.api_key # pragma: allowlist secret
    }
  }

  depends_on = [ibm_backup_recovery_protection_group.protection_group]
}

##############################################################################
# Tag cluster with BRS instance information
##############################################################################

# Adds BRS tags to identify which instance is protecting this cluster.
# Set add_cluster_tags = false to prevent tag drift when cluster tags are managed externally.
resource "ibm_resource_tag" "cluster_brs_tag" {
  count = local.stage_protection_groups && var.add_cluster_tags ? 1 : 0

  resource_id = local.cluster_crn
  tag_type    = "user"
  tags        = ["brs-region:${local.brs_instance_region}", "brs-guid:${local.brs_instance_guid}"]
}

##############################################################################
# Auto-protect cleanup (local-exec provisioner for destroy)
##############################################################################

# When auto-protect is enabled for the registration, it creates a protection
# group that is not currently deletable via terraform. This resource uses a
# local-exec provisioner to call a script that deletes the protection group.
resource "terraform_data" "delete_auto_protect_pg" {
  depends_on = [terraform_data.install_dependencies]
  count      = local.stage_protection_groups && var.enable_auto_protect && var.auto_protect_policy_name != null ? 1 : 0

  input = {
    region              = local.brs_instance_region
    tenant              = local.brs_tenant_id
    protection_group_id = try(ibm_backup_recovery_source_registration.source_registration[0].kubernetes_params[0].auto_protect_config[0].protection_group_id, "")
    brs_endpoint        = local.backup_recovery_instance_url
    api_key             = sensitive(var.ibmcloud_api_key)
  }

  triggers_replace = {
    api_key = sensitive(var.ibmcloud_api_key)
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "${path.module}/scripts/delete_auto_protect_pg.sh '${self.input.region}' '${self.input.tenant}' '${self.input.protection_group_id}' '${self.input.brs_endpoint}'"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      IBMCLOUD_API_KEY = self.triggers_replace.api_key # pragma: allowlist secret
    }
  }
}


##############################################################################
# Locals — Recovery Helpers
##############################################################################

locals {
  # Convert full PG ID format (clusterid/::timestamp:id:id) to numeric format
  # (timestamp:id:id) — required by the protection_group_runs data source.
  # Example: "5n3kwor5cb/::8009179080677672:1753125047518:126734"
  #       -> "8009179080677672:1753125047518:126734"
  numeric_pg_ids = local.deploy_recovery ? {
    for pg_name, pg_resource in ibm_backup_recovery_protection_group.protection_group :
    pg_name => split("::", pg_resource.id)[1]
  } : {}

  # Map of protection group name to the latest successful snapshot ID.
  # Populated only after wait_for_backup_run confirms a completed run exists.
  latest_snapshots = local.deploy_recovery ? {
    for pg_name, runs in data.ibm_backup_recovery_protection_group_runs.backup_runs :
    pg_name => (
      length(try(runs.runs, [])) > 0 ? (
        try(runs.runs[0].local_backup_info[0].snapshot_info[0].snapshot_id, try(runs.runs[0].id, null))
      ) : null
    )
  } : {}

  # Target cluster for recovery operations.
  # For cross-cluster recovery the target must be pre-registered with the same BRS instance.
  target_cluster_id = var.recovery_mode == "cross-cluster" ? var.target_cluster_id : var.cluster_id
}

##############################################################################
# Immediate Backup Trigger for Recovery Mode
##############################################################################

# Small delay to ensure protection group is fully registered before triggering backup
resource "time_sleep" "wait_for_pg_registration" {
  count = local.stage_backup_and_recovery && local.deploy_recovery ? 1 : 0

  depends_on = [
    ibm_backup_recovery_protection_group.protection_group,
    terraform_data.wait_for_source_discovery
  ]

  create_duration = "90s" # Increased to 90s to match solution wrapper

  triggers = {
    protection_group_ids = join(",", [for pg in ibm_backup_recovery_protection_group.protection_group : pg.id])
  }
}

# Trigger an immediate on-demand backup run for each protection group in recovery mode,
# but only if BRS has not already started one automatically (which it does as soon as a
# protection group is registered against an active policy).
# Blindly firing a second kRegular run while a CloudArchiveDirect archival task is in
# progress causes: "CloudArchiveDirect job has an active archival task for primary target".
resource "terraform_data" "trigger_backup_run" {
  for_each = local.stage_backup_and_recovery && local.deploy_recovery ? { for pg in var.protection_groups : pg.name => pg } : {}

  depends_on = [
    ibm_backup_recovery_protection_group.protection_group,
    terraform_data.wait_for_source_discovery,
    time_sleep.wait_for_pg_registration,
    terraform_data.install_dependencies
  ]

  input = {
    url                 = "https://${local.backup_recovery_instance_url}"
    tenant              = local.brs_tenant_id
    endpoint_type       = var.brs_endpoint_type
    instance_id         = local.brs_instance_guid
    protection_group_id = ibm_backup_recovery_protection_group.protection_group[each.key].id
    api_key             = sensitive(var.ibmcloud_api_key)
    binaries_path       = local.binaries_path
  }

  triggers_replace = {
    protection_group_id = ibm_backup_recovery_protection_group.protection_group[each.key].id
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/trigger_backup_run.sh '${self.input.url}' '${self.input.tenant}' '${self.input.endpoint_type}' '${self.input.instance_id}' '${self.input.protection_group_id}'"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key # pragma: allowlist secret
    }
  }
}

##############################################################################
# Active Backup Polling (Replaces Blind Wait)
##############################################################################

# Actively poll for backup completion instead of blind waiting
# This script checks backup status every 30 seconds until completion or timeout
resource "terraform_data" "wait_for_backup_run" {
  for_each = local.stage_backup_and_recovery && local.deploy_recovery ? { for pg in var.protection_groups : pg.name => pg } : {}

  depends_on = [
    ibm_backup_recovery_protection_group.protection_group,
    terraform_data.wait_for_source_discovery,
    terraform_data.trigger_backup_run,
    terraform_data.install_dependencies
  ]

  input = {
    url                   = "https://${local.backup_recovery_instance_url}"
    tenant                = local.brs_tenant_id
    endpoint_type         = var.brs_endpoint_type
    instance_id           = local.brs_instance_guid
    protection_group_id   = ibm_backup_recovery_protection_group.protection_group[each.key].id
    api_key               = sensitive(var.ibmcloud_api_key)
    timeout_minutes       = var.backup_run_poll_timeout_minutes
    poll_interval_seconds = var.backup_run_poll_interval_seconds
    binaries_path         = local.binaries_path
  }

  triggers_replace = {
    protection_group_id   = ibm_backup_recovery_protection_group.protection_group[each.key].id
    timeout_minutes       = tostring(var.backup_run_poll_timeout_minutes)
    poll_interval_seconds = tostring(var.backup_run_poll_interval_seconds)
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/wait_for_backup_run.sh '${self.input.url}' '${self.input.tenant}' '${self.input.endpoint_type}' '${self.input.instance_id}' '${self.input.protection_group_id}' '${self.input.timeout_minutes}' '${self.input.poll_interval_seconds}' '${self.input.binaries_path}'"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      IBMCLOUD_API_KEY = self.input.api_key
    }
  }
}

##############################################################################
# Query Protection Group Runs (Snapshot Discovery)
##############################################################################

# Data source to discover completed backup snapshots after polling confirms they exist
data "ibm_backup_recovery_protection_group_runs" "backup_runs" {
  for_each = local.stage_backup_and_recovery && local.deploy_recovery ? { for pg in var.protection_groups : pg.name => pg } : {}

  x_ibm_tenant_id        = local.brs_tenant_id
  protection_group_id    = local.numeric_pg_ids[each.key]
  endpoint_type          = var.brs_endpoint_type
  instance_id            = local.brs_instance_guid
  region                 = local.brs_instance_region
  include_object_details = true
  archival_run_status    = ["Succeeded", "SucceededWithWarning"]

  depends_on = [
    terraform_data.wait_for_backup_run,
    ibm_backup_recovery_protection_group.protection_group
  ]
}

##############################################################################
# Restore the backups to Same or Different Cluster
##############################################################################

resource "ibm_backup_recovery" "recover_snapshot" {
  for_each = local.stage_backup_and_recovery && local.deploy_recovery ? { for recovery in var.recoveries : recovery.name => recovery } : {}

  x_ibm_tenant_id      = local.brs_tenant_id
  name                 = each.value.name
  snapshot_environment = each.value.snapshot_environment
  endpoint_type        = var.brs_endpoint_type
  instance_id          = local.brs_instance_guid
  region               = local.brs_instance_region

  # Kubernetes-specific recovery parameters
  dynamic "kubernetes_params" {
    for_each = each.value.kubernetes_params != null ? [each.value.kubernetes_params] : []
    content {
      recovery_action = kubernetes_params.value.recovery_action

      # Objects to recover
      dynamic "objects" {
        for_each = kubernetes_params.value.objects
        content {
          snapshot_id           = objects.value.snapshot_id
          point_in_time_usecs   = objects.value.point_in_time_usecs
          protection_group_id   = objects.value.protection_group_id
          protection_group_name = objects.value.protection_group_name
          recover_from_standby  = objects.value.recover_from_standby
        }
      }
    }
  }

  depends_on = [
    terraform_data.wait_for_backup_run,
    data.ibm_backup_recovery_protection_group_runs.backup_runs,
    ibm_backup_recovery_protection_group.protection_group,
    ibm_backup_recovery_source_registration.source_registration
  ]

  lifecycle {
    # BRS recoveries are immutable audit records — the API rejects DELETE.
    # If terraform destroy fails on this resource, remove it from state:
    #   terraform state rm 'module.<mod>.ibm_backup_recovery.recover_snapshot["<name>"]'
    ignore_changes = [name]

    precondition {
      condition     = length(local.latest_snapshots) > 0
      error_message = <<-EOT
        No backup snapshots found. Recovery cannot proceed without completed backups.
        The module actively polls for backup completion (up to backup_run_poll_timeout_minutes).
        Either:
        1. Increase backup_run_poll_timeout_minutes to allow more time for backups to complete
        2. Ensure protection groups have run at least one successful backup before recovery
      EOT
    }

    precondition {
      condition = (
        var.recovery_mode == "same-cluster" ||
        (var.recovery_mode == "cross-cluster" && var.target_cluster_id != null && var.target_cluster_resource_group_id != null)
      )
      error_message = "For cross-cluster recovery, both target_cluster_id and target_cluster_resource_group_id must be provided."
    }
  }

}
