# Migration Guide

This guide covers upgrading to the new major version of `terraform-ibm-iks-ocp-backup-recovery` and the `solutions/fully-configurable` Deployable Architecture (DA).


## Summary of breaking changes

1. **The root module no longer creates the BRS instance.** Create the BRS instance first with `terraform-ibm-modules/backup-recovery/ibm`, then pass its outputs to this module.
2. **Root module inputs removed.** Several inputs were removed. See [Root module variables](#root-module-variables).
3. **Deployable Architecture inputs renamed.** Source and target cluster inputs now use a `source_` or `target_` prefix. See [Deployable Architecture variables](#deployable-architecture-variables).
4. **Root module outputs removed.** `brs_vpe_ips` and `s2s_auth_policies` are no longer output by the root module.
5. **Provider alias removed.** `configuration_aliases = [ibm.cluster]` was removed from the root module's `version.tf`.
6. **Execution stages.** The new `execution_stage` input (`cluster_prep`, `brs_management`, `all`, `custom`) splits the work into stages.
7. **IBM Cloud Provider minimum version.** The minimum required IBM Cloud provider version is now `>= 2.10.0, < 3.0.0` (raised to support `ibm_backup_recovery_connectors_metadata`).

## Step 1: Create the BRS instance

Create the BRS instance and connection with `terraform-ibm-modules/backup-recovery/ibm`, then pass its outputs to this module.

```hcl
module "brs_instance" {
  source  = "terraform-ibm-modules/backup-recovery/ibm"
  version = "1.12.3"

  # See the module's README for the full list of inputs.
}
```

| Input to this module | Value from the BRS instance module |
|---|---|
| `brs_instance_crn` | `module.brs_instance.brs_instance_crn` |
| `brs_instance_guid` | `module.brs_instance.brs_instance_guid` |
| `brs_tenant_id` | `module.brs_instance.tenant_id` |
| `brs_connection_id` | `module.brs_instance.connection_id` |
| `brs_registration_token` | `module.brs_instance.registration_token` |
| `brs_instance_public_url` | `module.brs_instance.brs_instance.extensions["endpoints.public"]` |
| `brs_instance_private_url` | `module.brs_instance.brs_instance.extensions["endpoints.private"]` |
| `resolved_policy_ids` | `module.brs_instance.resolved_policy_ids` |

Set `brs_endpoint_type` to `"public"` or `"private"` to choose which URL is used.

## Root module variables

### Removed

| Removed variable | What to do |
|---|---|
| `create_new_brs_instance`, `existing_brs_instance_crn`, `brs_instance_name` | Create the instance with the module in Step 1. |
| `brs_resource_group_id`, `region` | Set these on the BRS instance module in Step 1. |
| `brs_connection_name`, `brs_create_new_connection` | Set these on the BRS instance module in Step 1. |
| `create_brs_vpe`, `brs_vpe_name`, `vpc_id`, `vpc_subnets` | VPE creation is handled by the Deployable Architecture. See `create_source_cluster_brs_vpe_gateway`. |
| `add_dsc_rules_to_cluster_sg` | Removed. Manage security group rules outside this module. |
| `policies`, `resource_tags`, `access_tags` | Create policies and tags outside this module, and pass the resolved policy IDs through `resolved_policy_ids`. |

### Added

| New variable | Purpose |
|---|---|
| `execution_stage` | Selects the stages to run: `cluster_prep`, `brs_management`, `all` or `custom`. |
| `brs_tenant_id`, `brs_connection_id`, `brs_registration_token`, `brs_instance_guid`, `brs_instance_crn` | Values from the BRS instance. See Step 1. |
| `brs_instance_public_url`, `brs_instance_private_url`, `brs_endpoint_type` | BRS endpoint selection. |
| `brsagent_token` | Service account token from the `cluster_prep` stage, used by `brs_management`. |
| `resolved_policy_ids` | Protection policy IDs resolved outside this module. |
| `enable_cluster_infra_prep`, `enable_dsc_helm_deployment`, `enable_brs_registration`, `enable_protection_groups`, `enable_backup_and_recovery` | Per-stage feature flags. |
| `datamover_tolerations` | Custom tolerations to patch onto the `cohesity-dm` Data Mover DaemonSet. Defaults to `[{ operator = "Exists" }]` to tolerate all taints across worker nodes. Set to `[]` to disable patching. |
| `datamover_service_type` | Service type used for datamover communication during source registration (`kHostPort` (default), `kNodePort`, `kLoadBalancer`, `kClusterIp`). |
| `datamover_hostport_number` | Host port the datamover DaemonSet listens on when `datamover_service_type = "kHostPort"` (default `33769`). |
| `dsc_chart_uri` | Now optional (`default = null`). When null, the chart URI is dynamically discovered from the Backup & Recovery Service connectors metadata API, with static plan-time resolution fallback. Explicit URI overrides remain supported. |
| `registration_images` | Now an optional input (`default = null`) that defaults to the BRS server-side defaults, while allowing custom overrides. |

## Deployable Architecture variables

| Previous name | New name |
|---|---|
| `cluster_id` | `source_cluster_id` |
| `cluster_resource_group_id` | `source_cluster_resource_group_id` |
| `cluster_region` | `source_cluster_region` |
| `kube_type` | `source_kube_type` |
| `connection_env_type` | `source_connection_env_type` |
| `cluster_config_endpoint_type` | `source_cluster_config_endpoint_type` |
| `brs_connection_name` | `source_brs_connection_name` |
| `brs_create_new_connection` | `source_brs_create_new_connection` |
| `brs_vpe_name` | `source_brs_vpe_name` |
| `create_brs_vpe` | `create_source_cluster_brs_vpe_gateway` |
| `vpc_id` | `source_vpc_id` |
| `vpc_subnets` | `source_vpc_subnets` |
| `dsc_storage_class` | `source_dsc_storage_class` |
| `create_dsc_worker_pool` | `source_create_dsc_worker_pool` |
| `dsc_worker_pool_flavor` | `source_dsc_worker_pool_flavor` |
| `target_create_brs_vpe` | `create_target_cluster_brs_vpe_gateway` |
| `recovery_storage_class_aliases` | `recovery_storage_class_mapping` |

New target-cluster inputs: `target_cluster_region`, `target_kube_type`, `target_dsc_worker_pool_flavor`, `target_ibmcloud_api_key`.

New in this release:

- `manage_vpc_block_csi_addon` (default `true`). Set to `false` if you manage the `vpc-block-csi-driver` addon outside this module.
- `vpc_block_csi_driver_version` (default `5.2`).
- `datamover_tolerations` (default `[{ operator = "Exists" }]`). Tolerations applied to the `cohesity-dm` DaemonSet so it can schedule on tainted worker nodes.
- `datamover_service_type` (default `kHostPort`) and `datamover_hostport_number` (default `33769`).
- `dsc_chart_uri` (default `null`). Allows dynamic discovery from BRS connectors metadata, or custom URI override.
- `registration_images` (default `null`). Allows custom image overrides for the BRS registration components.

## Outputs

| Removed output | Replacement |
|---|---|
| `brs_vpe_ips` (root module) | Use the `brs_vpe_ips` output of the Deployable Architecture. |
| `s2s_auth_policies` (root module) | Create the S2S IAM policy with `terraform-ibm-modules/s2s-auth/ibm`. See the examples. |

## Validate

After applying, confirm:

- The source registration appears in BRS and points at your cluster.
- The DSC pods are running in the `ibm-brs-data-source-connector` namespace.
- The datamover DaemonSet pods (`cohesity-dm`) are running across worker nodes including any tainted pools.
- A test protection group runs a backup.
