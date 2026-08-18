##############################################################################
# Execution Stage & Phase Control Variables
##############################################################################

variable "execution_stage" {
  description = "Execution stage profile for the module: 'all' (runs everything end-to-end), 'cluster_prep' (runs only cluster discovery, worker pools, SG rules, and Helm DSC deployment), 'brs_management' (runs BRS source registration, protection groups, and backups/recoveries), or 'custom' (uses granular enable_* flags)."
  type        = string
  default     = "all"

  validation {
    condition     = contains(["all", "cluster_prep", "brs_management", "custom"], var.execution_stage)
    error_message = "Valid values for execution_stage are 'all', 'cluster_prep', 'brs_management', or 'custom'."
  }
}

variable "enable_cluster_infra_prep" {
  description = "When true, fetches cluster data sources, creates DSC worker pools, and sets DSC security group rules. In 'custom' stage, this flag is evaluated directly."
  type        = bool
  default     = true
}

variable "enable_dsc_helm_deployment" {
  description = "When true, creates the DSC namespace, Kubernetes RBAC/secrets, and deploys the Data Source Connector Helm chart. In 'custom' stage, this flag is evaluated directly."
  type        = bool
  default     = true
}

variable "enable_brs_registration" {
  description = "When true, registers the cluster as a protection source in the BRS instance and waits for discovery. In 'custom' stage, this flag is evaluated directly."
  type        = bool
  default     = true
}

variable "enable_protection_groups" {
  description = "When true, creates BRS protection groups, applies cluster BRS tags, and configures backup policies. In 'custom' stage, this flag is evaluated directly."
  type        = bool
  default     = true
}

variable "enable_backup_and_recovery" {
  description = "When true, triggers on-demand backup runs, polls for completion, and executes recovery snapshots. In 'custom' stage, this flag is evaluated directly."
  type        = bool
  default     = true
}


##############################################################################
# Cluster variables
##############################################################################

variable "cluster_id" {
  description = "The ID of the cluster designated for backup and recovery."
  type        = string
}

variable "add_cluster_tags" {
  description = "Whether to add BRS tags to the cluster. Set to false if you manage cluster tags externally to avoid drift. When false, you should manually add the tags 'brs-region:<region>' and 'brs-guid:<guid>' to your cluster."
  type        = bool
  default     = true
}

variable "cluster_resource_group_id" {
  description = "Resource group ID the cluster is deployed in."
  type        = string
}

variable "cluster_config_endpoint_type" {
  description = "The type of endpoint to use for the cluster config access: `default`, `private`, `vpe`, or `link`. The `default` value uses the default endpoint of the cluster."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "private", "vpe", "link"], var.cluster_config_endpoint_type)
    error_message = "Invalid endpoint type. Valid values are `default`, `private`, `vpe`, or `link`."
  }

  nullable = false
}

variable "kube_type" {
  description = "Specify the type of target cluster for the backup and recovery. Accepted values are `openshift` or `kubernetes`."
  type        = string
  default     = "openshift"

  validation {
    condition = contains([
      "openshift",
      "kubernetes",
    ], var.kube_type)
    error_message = "Accepted values are: `openshift` or `kubernetes`."
  }
}

# rollback_on_failure intentionally removed — DSC docs §8 explicitly forbid
# helm rollbacks; atomic mode is hard-coded to false in the helm_release resource.

variable "wait_till" {
  description = "To avoid long wait times when you run your Terraform code, you can specify the stage when you want Terraform to mark the cluster resource creation as completed. Depending on what stage you choose, the cluster creation might not be fully completed and continues to run in the background. However, your Terraform code can continue to run without waiting for the cluster to be fully created. Supported args are `MasterNodeReady`, `OneWorkerNodeReady`, `IngressReady` and `Normal`"
  type        = string
  default     = "Normal"

  validation {
    condition = contains([
      "MasterNodeReady",
      "OneWorkerNodeReady",
      "IngressReady",
      "Normal"
    ], var.wait_till)
    error_message = "`wait_till` value must be one of `MasterNodeReady`, `OneWorkerNodeReady`, `IngressReady` or `Normal`."
  }
}

variable "wait_till_timeout" {
  description = "Timeout for wait_till in minutes."
  type        = number
  default     = 90
}

variable "install_required_binaries" {
  type        = bool
  default     = true
  description = "When set to true, a script will run to check if `kubectl` and `jq`, `IBM Cloud CLI (ibmcloud)`, and the `backup-recovery plugin` exist on the runtime and if not attempt to download them from the public internet and install them to /tmp. Set to false to skip running this script."
  nullable    = false
}

##############################################################################
# Data Source Connector (DSC)
##############################################################################

variable "add_dsc_rules_to_cluster_sg" {
  description = "Set to `true` to automatically add the security group rules required by the Data Source Connector. This is mandatory when registering the cluster via its public service endpoint. Set to `false` to only register the cluster and create the policy without modifying security groups."
  type        = bool
  default     = false
}

variable "dsc_chart_uri" {
  description = "The full OCI registry URI for the Data Source Connector Helm chart, including the digest."
  type        = string
  default     = "oci://icr.io/brs-charts/brs-ds-connector-chart:7.3.12-release-20260713-2e7241a2@sha256:b6a39948f5d1b6f765d0e73ebd2dd9c700ba0d5d5a120969efdfce2f75e8467e"
  nullable    = false
}

variable "dsc_name" {
  description = "Release name for the Data Source Connector Helm deployment."
  type        = string
  default     = "dsc"
  nullable    = false
}

variable "dsc_replicas" {
  description = <<-EOT
  Number of Data Source Connector pods to run.
  Recommended values:
    • 3 – for high availability across multiple nodes/zones (strongly recommended in production)
    • 1 – only for dev/test or single-node clusters
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.dsc_replicas >= 1
    error_message = "Replicas must be at least 1."
  }

  nullable = false
}

variable "dsc_helm_timeout" {
  description = "Timeout in seconds for the Data Source Connector Helm deployment."
  type        = number
  default     = 7200
  nullable    = false
}

variable "dsc_namespace" {
  description = "The cluster namespace where the Data Source Connector will be installed. Will be created if it does not exist."
  type        = string
  default     = "ibm-brs-data-source-connector"
  nullable    = false
}

variable "dsc_storage_class" {
  description = "Storage class to use for the Data Source Connector persistent volume. By default, it uses 'ibmc-vpc-block-metro-5iops-tier' for VPC clusters and 'ibmc-block-silver' for Classic clusters."
  type        = string
  default     = null
}

variable "create_dsc_worker_pool" {
  description = "Set to `true` to create a dedicated worker pool for the Data Source Connector in VPC clusters. If set to `false`, the connector will be deployed on existing worker nodes."
  type        = bool
  default     = true
}

variable "dsc_worker_pool_zones" {
  description = "Number of zones to create worker pools in. Defaults to 1 for single-zone deployments. Set to 2 or 3 for multi-zone high availability. Must be between 1 and 3."
  type        = number
  default     = 1

  validation {
    condition     = var.dsc_worker_pool_zones >= 1 && var.dsc_worker_pool_zones <= 3
    error_message = "dsc_worker_pool_zones must be between 1 and 3."
  }
}

variable "dsc_worker_pool_flavor" {
  description = "The machine flavor for the Data Source Connector worker pool. `bxf.4x16` (4 vCPU, 16 GB RAM) is available in every IBM Cloud VPC zone. Override for a larger flavor (e.g. `bxf.8x32`)."
  type        = string
  default     = "bxf.4x16"
  nullable    = false
}

variable "dsc_pod_cpu_limits" {
  description = "CPU limit for each Data Source Connector pod (e.g., '4', '8'). Should match or exceed the worker node's available CPU."
  type        = string
  default     = "4"
  nullable    = false
}

variable "dsc_pod_memory_limits" {
  description = "Memory limit for each Data Source Connector pod (e.g., '8Gi', '16Gi'). Should match or exceed the worker node's available memory."
  type        = string
  default     = "8Gi"
  nullable    = false
}

variable "dsc_pod_cpu_requests" {
  description = "CPU request for each Data Source Connector pod (e.g., '2', '4'). This is the guaranteed CPU allocation."
  type        = string
  default     = "2"
  nullable    = false
}

variable "dsc_pod_memory_requests" {
  description = "Memory request for each Data Source Connector pod (e.g., '5Gi', '10Gi'). This is the guaranteed memory allocation."
  type        = string
  default     = "5Gi"
  nullable    = false
}

##############################################################################
# BRS prerequisite inputs — required, provided by the caller (DA or example)
##############################################################################

variable "brs_tenant_id" {
  description = "Tenant ID of the BRS instance. Provided by the DA or example that owns the BRS instance."
  type        = string
  sensitive   = true
  default     = null
}

variable "brs_connection_id" {
  description = "Connection ID of the BRS data-source connection. Provided by the DA or example that owns the BRS instance."
  type        = string
  sensitive   = true
  default     = null
}

variable "brs_registration_token" {
  description = "Registration token used to register the DSC with the BRS instance. Provided by the DA or example that owns the BRS instance."
  type        = string
  sensitive   = true
  default     = null
}

variable "brs_instance_guid" {
  description = "GUID of the BRS service instance. Provided by the DA or example that owns the BRS instance."
  type        = string
  default     = null
}

variable "brs_instance_crn" {
  description = "CRN of the BRS service instance. Provided by the DA or example that owns the BRS instance."
  type        = string
  default     = null
  validation {
    condition     = var.brs_instance_crn == null || can(regex("^crn:v1:", var.brs_instance_crn))
    error_message = "'brs_instance_crn' must be null or a valid CRN beginning with 'crn:v1:'."
  }
}

variable "brs_instance_public_url" {
  description = "Public endpoint URL of the BRS instance (without scheme). Provided by the DA or example that owns the BRS instance."
  type        = string
  default     = null
}

variable "brs_instance_private_url" {
  description = "Private endpoint URL of the BRS instance (without scheme). Provided by the DA or example that owns the BRS instance."
  type        = string
  default     = null
}

variable "resolved_policy_ids" {
  description = "Map of policy name → policy ID resolved by the caller's BRS instance module."
  type        = map(string)
  default     = null
}

##############################################################################
# IBM Cloud API key (still used by scripts in the root module)
##############################################################################

variable "ibmcloud_api_key" {
  description = "The IBM Cloud API key used to generate IAM tokens for scripts (cancel_pg_runs, wait-for-deregistration, etc.)."
  type        = string
  sensitive   = true
}

variable "brs_endpoint_type" {
  description = "The endpoint type to use when connecting to the Backup and Recovery service for Terraform provider operations and script calls. Allowed values are 'public' or 'private'. When a BRS VPE Gateway is active and this is set to 'private', the DSC pods reach BRS over the Virtual Private Endpoint Gateway (VPE) instead of the IBM Cloud Service Endpoint (CSE) — the BRS endpoint URL is automatically overridden to the VPE DNS hostname inside the cluster VPC."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["public", "private"], var.brs_endpoint_type)
    error_message = "`brs_endpoint_type` must be 'public' or 'private'."
  }
}

variable "connection_env_type" {
  description = "Connection environment type to determine the required parameters for creating a new connection. Must be consistent with `kube_type` (use `kIks*` for `kubernetes`, `kRoks*` for `openshift`). Allowed values are 'kIksVpc', 'kRoksVpc', 'kRoksClassic', and 'kIksClassic'."
  type        = string

  validation {
    condition     = contains(["kIksVpc", "kRoksVpc", "kRoksClassic", "kIksClassic"], var.connection_env_type)
    error_message = "`connection_env_type` must be one of 'kIksVpc', 'kRoksVpc', 'kRoksClassic', or 'kIksClassic'."
  }
}

##############################################################################
# Use Case Control Flags
##############################################################################

variable "deployment_mode" {
  description = <<-DESC
    Deployment mode to control what components are deployed:
    - 'backup_only' (default): Registers source cluster with BRS, configures protection groups. No target cluster, no recovery.
    - 'connected_component': Registers both source + target clusters with BRS for cluster connection setup only. No backup or recovery triggered.
    - 'full_backup_recovery': End-to-end: registers clusters, triggers on-demand backup, waits for completion, executes recovery to validate.
  DESC
  type        = string
  default     = "backup_only"

  validation {
    condition     = contains(["backup_only", "connected_component", "full_backup_recovery"], var.deployment_mode)
    error_message = "`deployment_mode` must be one of 'backup_only', 'connected_component', or 'full_backup_recovery'."
  }
}

##############################################################################
# Protection Policy
##############################################################################

variable "auto_protect_policy_name" {
  description = "Name of an existing protection policy to use for auto-protect. Required when `enable_auto_protect` is `true` and deployment_mode is 'backup_only' or 'full_backup_recovery'. The policy must already exist in the BRS instance (create it using the `terraform-ibm-backup-recovery` module)."
  type        = string
  default     = null

  validation {
    condition = (
      var.deployment_mode == "connected_component" ||
      var.enable_auto_protect == false ||
      (var.enable_auto_protect == true && var.auto_protect_policy_name != null)
    )
    error_message = "auto_protect_policy_name is required when enable_auto_protect is true in 'backup_only' or 'full_backup_recovery' modes."
  }
}

variable "enable_auto_protect" {
  description = "Enable auto-protect during the initial cluster registration. This must be set to `true` on the first run; toggling it from `false` to `true` later is not supported by the underlying API and will not retroactively create the protection group."
  type        = bool
  default     = true
}
variable "backup_run_poll_timeout_minutes" {
  description = "Maximum time in minutes to poll for the first restorable backup run when recovery is enabled in a single apply."
  type        = number
  default     = 45

  validation {
    condition     = var.backup_run_poll_timeout_minutes >= 1
    error_message = "backup_run_poll_timeout_minutes must be at least 1."
  }
}

variable "backup_run_poll_interval_seconds" {
  description = "Polling interval in seconds when waiting for the first restorable backup run."
  type        = number
  default     = 30

  validation {
    condition     = var.backup_run_poll_interval_seconds >= 5
    error_message = "backup_run_poll_interval_seconds must be at least 5."
  }
}

##############################################################################
# Protection Groups (granular backup control)
##############################################################################

variable "protection_groups" {
  description = "List of protection groups for granular backup control. Each group selects specific namespaces/objects and applies a policy. Use this as an alternative to `enable_auto_protect` for fine-grained control over which workloads are backed up."
  type = list(object({
    name        = string
    policy_name = string
    description = optional(string)

    # --- Kubernetes-specific params ---
    enable_indexing       = optional(bool, true)
    leverage_csi_snapshot = optional(bool, false)
    non_snapshot_backup   = optional(bool, false)
    volume_backup_failure = optional(bool, false)

    # Objects (namespaces) to protect
    objects = optional(list(object({
      id                          = optional(number)
      name                        = optional(string)
      backup_only_pvc             = optional(bool, false)
      fail_backup_on_hook_failure = optional(bool, false)
      included_resources          = optional(list(string))
      excluded_resources          = optional(list(string))
      include_pvcs = optional(list(object({
        id   = optional(number)
        name = optional(string)
      })))
      exclude_pvcs = optional(list(object({
        id   = optional(number)
        name = optional(string)
      })))

      # Per-object label-based PV/PVC inclusion
      include_params = optional(object({
        label_combination_method = optional(string, "AND") # AND, OR
        label_vector = optional(list(object({
          key   = string
          value = string
        })))
        objects = optional(list(object({}))) # usually any or map but provider says array of objects
        selected_resources = optional(list(object({
          api_group         = optional(string)
          is_cluster_scoped = optional(bool)
          kind              = optional(string)
          name              = optional(string)
          version           = optional(string)
          resource_list = optional(list(object({
            entity_id = optional(number)
            name      = optional(string)
          })))
        })))
      }))

      # Per-object label-based PV/PVC exclusion
      exclude_params = optional(object({
        label_combination_method = optional(string, "AND")
        label_vector = optional(list(object({
          key   = string
          value = string
        })))
        objects = optional(list(object({})))
        selected_resources = optional(list(object({
          api_group         = optional(string)
          is_cluster_scoped = optional(bool)
          kind              = optional(string)
          name              = optional(string)
          version           = optional(string)
          resource_list = optional(list(object({
            entity_id = optional(number)
            name      = optional(string)
          })))
        })))
      }))

      # Quiescing rules for app-consistent backups
      quiesce_groups = optional(list(object({
        quiesce_mode = string # kQuiesceTogether, kQuiesceIndependently
        quiesce_rules = list(object({
          pod_selector_labels = optional(list(object({
            key   = string
            value = string
          })))
          pre_snapshot_hooks = list(object({
            commands      = list(string)
            container     = optional(string)
            fail_on_error = optional(bool, false)
            timeout       = optional(number)
          }))
          post_snapshot_hooks = list(object({
            commands      = list(string)
            container     = optional(string)
            fail_on_error = optional(bool, false)
            timeout       = optional(number)
          }))
        }))
      })))
    })))

    # Object IDs to exclude
    exclude_object_ids = optional(list(number))

    # Label-based namespace selection (2D array of label IDs)
    label_ids         = optional(list(number))
    exclude_label_ids = optional(list(number))

    # Global label-based inclusion filter
    include_params = optional(object({
      label_combination_method = optional(string, "AND") # AND, OR
      label_vector = optional(list(object({
        key   = string
        value = string
      })))
      objects = optional(list(object({})))
      selected_resources = optional(list(object({
        api_group         = optional(string)
        is_cluster_scoped = optional(bool)
        kind              = optional(string)
        name              = optional(string)
        version           = optional(string)
        resource_list = optional(list(object({
          entity_id = optional(number)
          name      = optional(string)
        })))
      })))
    }))

    # Global label-based exclusion filter
    exclude_params = optional(object({
      label_combination_method = optional(string, "AND")
      label_vector = optional(list(object({
        key   = string
        value = string
      })))
      objects = optional(list(object({})))
      selected_resources = optional(list(object({
        api_group         = optional(string)
        is_cluster_scoped = optional(bool)
        kind              = optional(string)
        name              = optional(string)
        version           = optional(string)
        resource_list = optional(list(object({
          entity_id = optional(number)
          name      = optional(string)
        })))
      })))
    }))

    # --- Alert policy ---
    alert_policy = optional(object({
      backup_run_status = list(string) # kFailure, kSuccess, kSlaViolation, kWarning
      alert_targets = optional(list(object({
        email_address  = string
        language       = optional(string, "en-us")
        recipient_type = optional(string, "kTo")
      })))
      raise_object_level_failure_alert                    = optional(bool)
      raise_object_level_failure_alert_after_each_attempt = optional(bool)
      raise_object_level_failure_alert_after_last_attempt = optional(bool)
    }))

    # --- SLA ---
    sla = optional(list(object({
      backup_run_type = optional(string, "kIncremental") # kIncremental, kFull, kLog
      sla_minutes     = number
    })))

    # --- Scheduling ---
    start_time = optional(object({
      hour      = number
      minute    = number
      time_zone = optional(string, "America/Los_Angeles")
    }))

    # --- Advanced configs (key/value pairs) ---
    advanced_configs = optional(list(object({
      key   = string
      value = string
    })))

    priority           = optional(string, "kMedium") # kLow, kMedium, kHigh
    qos_policy         = optional(string)            # kBackupHDD, kBackupSSD, etc.
    is_paused          = optional(bool, false)
    abort_in_blackouts = optional(bool, false)
    pause_in_blackouts = optional(bool, false)
    delete_snapshots   = optional(bool, false) # When true, all snapshots are deleted when the Protection Group is destroyed
  }))
  default  = []
  nullable = false
}

##############################################################################
# Registration Images
##############################################################################

variable "registration_images" {
  description = "The images required for backup and recovery registration."
  type = object({
    data_mover                  = string
    velero                      = string
    velero_aws_plugin           = string
    velero_openshift_plugin     = optional(string, null)
    cohesity_dataprotect_plugin = string
    init_container              = optional(string, null)
  })
  default = {
    data_mover                  = "icr.io/ext/brs/cohesity-datamover:7.3.12@sha256:0a0e87ddce1165398390656e6ff9465815a105a79c427030f284bffbc2b7d987"
    velero                      = "icr.io/ext/brs/oadp-velero:1.5.5@sha256:386ef8dff743339a40b3b82a1fcdc9bda56c0d31a0b544acae59058d522db8d7"
    velero_aws_plugin           = "icr.io/ext/brs/oadp-velero-plugin-for-aws:1.5.5@sha256:93a7f4c514546a1d771186b8e60722d3b1632190ebc02f4a8e75e8fe0f867ced"
    velero_openshift_plugin     = "icr.io/ext/brs/oadp-velero-plugin-for-openshift:1.5.5@sha256:130894d2eca06a0e5eb49b969c03c99ed0d5a9d0cac83126e360442d438c9f2d"
    cohesity_dataprotect_plugin = "icr.io/ext/brs/cohesity-dataprotect-plugin:7.3.12@sha256:7c68cf893694f1057c700cfe223fdd86ae455889295f9f353c22d9d443170182"
  }
  nullable = false
}

##############################################################################
# Recovery Variables
##############################################################################

variable "recovery_mode" {
  description = "Recovery mode: 'same-cluster' to restore within the same cluster, or 'cross-cluster' to restore to a different target cluster. Requires `deployment_mode = 'full_backup_recovery'` to take effect."
  type        = string
  default     = "same-cluster"

  validation {
    condition     = contains(["same-cluster", "cross-cluster"], var.recovery_mode)
    error_message = "recovery_mode must be either 'same-cluster' or 'cross-cluster'."
  }
}

variable "target_cluster_id" {
  description = "Target cluster ID for cross-cluster recovery or connected component setup. Required when `var.recovery_mode` is 'cross-cluster' or when `deployment_mode` is 'connected_component'. Must be a cluster already registered with the BRS instance."
  type        = string
  default     = null

  validation {
    condition = (
      var.deployment_mode == "backup_only" ||
      (var.deployment_mode == "connected_component" && var.target_cluster_id != null) ||
      (var.deployment_mode == "full_backup_recovery" && var.recovery_mode == "same-cluster") ||
      (var.deployment_mode == "full_backup_recovery" && var.recovery_mode == "cross-cluster" && var.target_cluster_id != null)
    )
    error_message = "target_cluster_id is required when deployment_mode is 'connected_component' or when recovery_mode is 'cross-cluster' in 'full_backup_recovery' mode."
  }
}

variable "target_cluster_resource_group_id" {
  description = "Resource group ID of the target cluster for cross-cluster recovery or connected component setup. Required when recovery_mode is 'cross-cluster' or when `deployment_mode` is 'connected_component'."
  type        = string
  default     = null

  validation {
    condition = (
      var.deployment_mode == "backup_only" ||
      (var.deployment_mode == "connected_component" && var.target_cluster_resource_group_id != null) ||
      (var.deployment_mode == "full_backup_recovery" && var.recovery_mode == "same-cluster") ||
      (var.deployment_mode == "full_backup_recovery" && var.recovery_mode == "cross-cluster" && var.target_cluster_resource_group_id != null)
    )
    error_message = "target_cluster_resource_group_id is required when deployment_mode is 'connected_component' or when recovery_mode is 'cross-cluster' in 'full_backup_recovery' mode."
  }
}


variable "recoveries" {
  description = "List of recovery operations to restore backups. These operations are triggered automatically after a backup run completes when recovery is enabled by the calling module. Each entry's `kubernetes_params.objects[*].snapshot_id` controls which backup is restored: supply an explicit snapshot ID to recover from any specific backup (not necessarily the one taken in the current apply), or use the `latest_snapshots` output to reference the most recent run. Supports multiple environments: Kubernetes, VMware, Physical, AWS, Azure, GCP, SQL, Oracle, and more. This variable follows the official IBM Backup Recovery provider schema. For IKS/ROKS recovery use `kubernetes_params`. See the Usage section in the README for examples."
  type = list(object({
    name                 = string
    snapshot_environment = string # kKubernetes, kVMware, kPhysical, kAWS, kAzure, kGCP, kSQL, kOracle, kView, etc.

    # Kubernetes-specific recovery parameters
    kubernetes_params = optional(object({
      recovery_action = string # RecoverNamespaces, RecoverPVs, RecoverApps

      objects = list(object({
        snapshot_id           = string
        point_in_time_usecs   = optional(number)
        protection_group_id   = optional(string)
        protection_group_name = optional(string)
        recover_from_standby  = optional(bool, false)
      }))
    }))

    # VMware-specific recovery parameters (for future provider support)
    vmware_params = optional(object({
      recovery_action = optional(string)
      objects = optional(list(object({
        snapshot_id           = optional(string)
        point_in_time_usecs   = optional(number)
        protection_group_id   = optional(string)
        protection_group_name = optional(string)
        recover_from_standby  = optional(bool, false)
      })))
    }))

    # Physical server recovery parameters (for future provider support)
    physical_params = optional(object({
      recovery_action = optional(string)
      objects = optional(list(object({
        snapshot_id           = optional(string)
        point_in_time_usecs   = optional(number)
        protection_group_id   = optional(string)
        protection_group_name = optional(string)
      })))
    }))

    # AWS-specific recovery parameters (for future provider support)
    aws_params = optional(object({
      recovery_action = optional(string)
      objects = optional(list(object({
        snapshot_id           = optional(string)
        point_in_time_usecs   = optional(number)
        protection_group_id   = optional(string)
        protection_group_name = optional(string)
      })))
    }))

    # Azure-specific recovery parameters (for future provider support)
    azure_params = optional(object({
      recovery_action = optional(string)
      objects = optional(list(object({
        snapshot_id           = optional(string)
        point_in_time_usecs   = optional(number)
        protection_group_id   = optional(string)
        protection_group_name = optional(string)
      })))
    }))

    # GCP-specific recovery parameters (for future provider support)
    gcp_params = optional(object({
      recovery_action = optional(string)
      objects = optional(list(object({
        snapshot_id           = optional(string)
        point_in_time_usecs   = optional(number)
        protection_group_id   = optional(string)
        protection_group_name = optional(string)
      })))
    }))

    # SQL-specific recovery parameters (for future provider support)
    sql_params = optional(object({
      recovery_action = optional(string)
      objects = optional(list(object({
        snapshot_id           = optional(string)
        point_in_time_usecs   = optional(number)
        protection_group_id   = optional(string)
        protection_group_name = optional(string)
      })))
    }))

    # Oracle-specific recovery parameters (for future provider support)
    oracle_params = optional(object({
      recovery_action = optional(string)
      objects = optional(list(object({
        snapshot_id           = optional(string)
        point_in_time_usecs   = optional(number)
        protection_group_id   = optional(string)
        protection_group_name = optional(string)
      })))
    }))
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for r in var.recoveries : contains([
        "kKubernetes", "kVMware", "kPhysical", "kAWS", "kAzure",
        "kGCP", "kSQL", "kOracle", "kView", "kPuppeteer",
        "kPhysicalFiles", "kPure", "kNimble", "kAzureNative",
        "kAD", "kAWSNative", "kGCPNative", "kKVM", "kAcropolis",
        "kExchange", "kHyperV", "kHyperVVSS", "kO365", "kO365Outlook",
        "kO365PublicFolders", "kO365Teams", "kO365Group", "kO365Exchange",
        "kO365OneDrive", "kO365Sharepoint", "kCassandra", "kMongoDB",
        "kCouchbase", "kHdfs", "kHive", "kHBase", "kUDA", "kSfdc"
      ], r.snapshot_environment)
    ])
    error_message = "snapshot_environment must be a valid environment type as per IBM Backup Recovery provider documentation."
  }
}
