# Cloud automation for OpenShift workloads Backup Recovery (Fully configurable)

## Overview

This Deployable Architecture (DA) solution provides comprehensive backup and recovery capabilities for IBM Cloud Kubernetes Service (IKS) and Red Hat OpenShift on IBM Cloud (ROKS) clusters using IBM Backup Recovery Service (BRS).

### Key Features

- **Automated Backup**: Configure protection policies and protection groups for automated backups
- **Flexible Recovery Options**:
  - **Same-Cluster Recovery**: Restore to the original cluster with namespace prefix
  - **Cross-Cluster Recovery**: Restore to a different target cluster
- **Auto-Protect**: Automatically protect all namespaces with a single policy
- **Granular Control**: Define specific protection groups for fine-grained backup control
- **Data Source Connector (DSC)**: Dedicated worker pool option for backup operations
- **Validation Testing**: Optional automatic recovery testing to validate backups

## Recovery Capabilities

### Same-Cluster Recovery

Restore backed-up namespaces to the same cluster where the backup was taken. Restored namespaces are created with a configurable prefix (default: `restored-`).

**Use Cases:**

- Testing backup integrity
- Recovering from accidental deletion
- Creating test environments from production backups

**Configuration:**

```hcl
enable_recovery              = true
recovery_type                = "same_cluster"
recovery_namespace_prefix    = "restored-"
recovery_protection_group_name = "my-protection-group"  # Optional, uses first PG if not specified
```

### Cross-Cluster Recovery

Restore backed-up namespaces from a source cluster to a different target cluster. This enables disaster recovery and migration scenarios.

**Use Cases:**

- Disaster recovery to a different region
- Migrating workloads between clusters
- Creating staging environments from production backups
- Testing recovery procedures

**Configuration:**

```hcl
enable_recovery                      = true
recovery_type                        = "cross_cluster"
target_cluster_id                    = "target-cluster-id"
target_cluster_resource_group_id     = "target-rg-id"
target_cluster_config_endpoint_type  = "private"
recovery_namespace_prefix            = "restored-"
target_brs_connection_name           = "target-cluster-connection"  # Optional
target_create_dsc_worker_pool        = true
```

### Recovery Process

When recovery is enabled, the solution automatically:

1. **Waits for Backup Completion**: Polls the BRS API until a successful backup completes
2. **Retrieves Snapshot ID**: Extracts the snapshot ID from the completed backup
3. **Registers Target Cluster** (cross-cluster only): Registers the target cluster with BRS
4. **Triggers Recovery**: Initiates the recovery operation using the BRS API
5. **Creates Restored Namespaces**: Namespaces are created with the configured prefix

### Recovery Configuration Variables

| Variable                         | Description                                         | Default        | Required |
| -------------------------------- | --------------------------------------------------- | -------------- | -------- |
| `enable_recovery`                | Enable automatic recovery testing                   | `false`        | No       |
| `recovery_type`                  | Type of recovery: `same_cluster` or `cross_cluster` | `same_cluster` | No       |
| `recovery_namespace_prefix`      | Prefix for restored namespaces                      | `restored-`    | No       |
| `recovery_protection_group_name` | Protection group to recover from                    | First PG       | No       |
| `recovery_wait_timeout_minutes`  | Max time to wait for backup                         | `45`           | No       |
| `recovery_poll_interval_seconds` | Polling interval for backup status                  | `30`           | No       |

**Cross-Cluster Only:**
| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `target_cluster_id` | Target cluster ID | - | Yes (for cross-cluster) |
| `target_cluster_resource_group_id` | Target cluster resource group | - | Yes (for cross-cluster) |
| `target_cluster_config_endpoint_type` | Target cluster endpoint type | `private` | No |
| `target_brs_connection_name` | BRS connection name for target | Auto-generated | No |
| `target_create_dsc_worker_pool` | Create DSC worker pool on target | `true` | No |

## Usage Examples

### Example 1: Basic Backup (No Recovery)

```hcl
module "backup_recovery" {
  source = "terraform-ibm-modules/iks-ocp-backup-recovery/ibm//solutions/fully-configurable"

  # Cluster Configuration
  cluster_id                = "my-cluster-id"
  cluster_resource_group_id = "my-resource-group-id"
  ibmcloud_api_key          = var.ibmcloud_api_key # pragma: allowlist secret

  # BRS Instance
  brs_instance_name = "my-brs-instance"
  region            = "us-south"

  # Connection
  brs_connection_name = "my-cluster-connection"

  # Auto-protect all namespaces
  enable_auto_protect      = true
  auto_protect_policy_name = "daily-backup"

  # Policy
  policies = [{
    name              = "daily-backup"
    create_new_policy = true
    schedule = {
      unit      = "Days"
      frequency = 1
    }
    retention = {
      unit     = "Days"
      duration = 7
    }
  }]
}
```

### Example 2: Same-Cluster Recovery

```hcl
module "backup_recovery" {
  source = "terraform-ibm-modules/iks-ocp-backup-recovery/ibm//solutions/fully-configurable"

  # ... (same cluster and BRS configuration as Example 1)

  # Enable same-cluster recovery
  enable_recovery           = true
  recovery_type             = "same_cluster"
  recovery_namespace_prefix = "test-restore-"

  # Recovery will automatically trigger after backup completes
}
```

### Example 3: Cross-Cluster Recovery

```hcl
module "backup_recovery" {
  source = "terraform-ibm-modules/iks-ocp-backup-recovery/ibm//solutions/fully-configurable"

  # Source Cluster Configuration
  cluster_id                = "source-cluster-id"
  cluster_resource_group_id = "source-rg-id"
  ibmcloud_api_key          = var.ibmcloud_api_key  # pragma: allowlist secret

  # BRS Instance
  brs_instance_name = "my-brs-instance"
  region            = "us-south"

  # Connection
  brs_connection_name = "source-cluster-connection"

  # Protection Group
  protection_groups = [{
    name        = "production-workloads"
    policy_name = "daily-backup"
    objects = [{
      name = "production-namespace"
    }]
  }]

  # Policy
  policies = [{
    name              = "daily-backup"
    create_new_policy = true
    schedule = {
      unit      = "Days"
      frequency = 1
    }
    retention = {
      unit     = "Days"
      duration = 7
    }
  }]

  # Enable cross-cluster recovery
  enable_recovery                     = true
  recovery_type                       = "cross_cluster"
  target_cluster_id                   = "target-cluster-id"
  target_cluster_resource_group_id    = "target-rg-id"
  target_cluster_config_endpoint_type = "private"
  recovery_namespace_prefix           = "dr-"
  target_brs_connection_name          = "target-cluster-connection"
}
```

### Example 4: Granular Protection Groups

```hcl
module "backup_recovery" {
  source = "terraform-ibm-modules/iks-ocp-backup-recovery/ibm//solutions/fully-configurable"

  # ... (cluster and BRS configuration)

  # Disable auto-protect for granular control
  enable_auto_protect = false

  # Define specific protection groups
  protection_groups = [
    {
      name        = "critical-apps"
      policy_name = "hourly-backup"
      priority    = "kHigh"
      objects = [{
        name = "production-namespace"
      }]
    },
    {
      name        = "dev-apps"
      policy_name = "daily-backup"
      priority    = "kLow"
      objects = [{
        name = "development-namespace"
      }]
    }
  ]

  # Multiple policies
  policies = [
    {
      name              = "hourly-backup"
      create_new_policy = true
      schedule = {
        unit      = "Hours"
        frequency = 1
      }
      retention = {
        unit     = "Days"
        duration = 3
      }
    },
    {
      name              = "daily-backup"
      create_new_policy = true
      schedule = {
        unit      = "Days"
        frequency = 1
      }
      retention = {
        unit     = "Days"
        duration = 7
      }
    }
  ]
}
```

## Recovery Outputs

When recovery is enabled, the solution provides additional outputs:

```hcl
output "recovery_status" {
  description = "Status message about recovery configuration"
  value       = module.backup_recovery.recovery_status
}

output "recovery_snapshot_id" {
  description = "Snapshot ID used for recovery"
  value       = module.backup_recovery.recovery_snapshot_id
  sensitive   = true
}

output "target_cluster_registration_id" {
  description = "Registration ID of target cluster (cross-cluster only)"
  value       = module.backup_recovery.target_cluster_registration_id
}
```

## Important Notes

### Recovery Behavior

1. **Automatic Execution**: When `enable_recovery = true`, recovery triggers automatically after the first successful backup
2. **One-Time Operation**: Recovery runs once per `terraform apply`. To test again, run `terraform apply` again
3. **Namespace Prefix**: Restored namespaces always have a prefix to avoid conflicts with existing namespaces
4. **Resource Restoration**: All Kubernetes resources in the namespace are restored (Deployments, Services, ConfigMaps, Secrets, PVCs, etc.)

### Best Practices

1. **Test Recovery Regularly**: Enable recovery in non-production environments to validate backup integrity
2. **Use Descriptive Prefixes**: Choose meaningful namespace prefixes for easy identification
3. **Monitor Recovery Jobs**: Check BRS console for recovery job status and logs
4. **Verify Restored Data**: After recovery, verify that applications and data are intact
5. **Clean Up Test Recoveries**: Delete test-restored namespaces after validation

### Limitations

1. **Provider Configuration**: This solution contains provider configuration and cannot be used with `for_each`, `count`, or `depends_on`
2. **Single Recovery Per Apply**: Only one recovery operation per `terraform apply`
3. **Target Cluster Requirements**: For cross-cluster recovery, target cluster must be in the same region as the BRS instance
4. **Network Connectivity**: Clusters must have network connectivity to BRS endpoints

## Prerequisites

- IBM Cloud account with appropriate permissions
- Existing IKS or ROKS cluster (source)
- For cross-cluster recovery: Additional target cluster
- IBM Cloud API key with required permissions
- Terraform >= 1.3.0

## Required IAM Permissions

- **Backup Recovery Service**: Editor or Administrator
- **Kubernetes Service**: Editor or Administrator
- **VPC Infrastructure**: Editor (if creating DSC worker pools)
- **Resource Group**: Viewer

:exclamation: **Important:** This solution is not intended to be called by other modules because it contains a provider configuration and is not compatible with the `for_each`, `count`, and `depends_on` arguments. For more information, see [Providers Within Modules](https://developer.hashicorp.com/terraform/language/modules/develop/providers).
