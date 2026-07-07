# Deployment Modes for IBM Backup & Recovery

This document describes the three deployment modes supported by this Terraform module for IBM Backup & Recovery Service integration with IKS/ROKS clusters.

## Overview

The module supports three distinct deployment modes to accommodate different use cases:

1. **Backup Only** (`deployment_mode = "backup_only"`) - Default mode for backup without recovery
2. **Connected Component** (`deployment_mode = "connected_component"`) - Connection setup for both clusters without backups
3. **Full Backup and Recovery** (`deployment_mode = "full_backup_recovery"`) - Complete end-to-end with backup and recovery

---

## Deployment Modes

### 1. Backup Only (Default)

**Use Case**: Non-migration scenarios where users only want backup capabilities. Registers source cluster with BRS and configures protection groups. No target cluster or recovery setup needed.

**What Gets Deployed**:

- ✅ Data Source Connector (DSC) via Helm
- ✅ Cluster source registration with BRS
- ✅ Protection groups for backup
- ✅ Security group rules (if VPC)
- ✅ BRS agent service account and RBAC

**What's NOT Deployed**:

- ❌ Target cluster registration
- ❌ Recovery resources
- ❌ Backup run polling for recovery
- ❌ Snapshot discovery for recovery

**Configuration**:

```hcl
module "backup_recovery" {
  source = "terraform-ibm-modules/iks-ocp-backup-recovery/ibm"

  deployment_mode = "backup_only"  # Default value

  cluster_id                = "your-cluster-id"
  cluster_resource_group_id = "your-rg-id"
  brs_connection_name       = "my-connection"

  # Protection groups for backup
  enable_auto_protect      = true
  auto_protect_policy_name = "daily-retention"

  # Or use granular protection groups
  protection_groups = [{
    name        = "production-backup"
    policy_name = "daily-retention"
    objects     = [{ name = "production-namespace" }]
  }]
}
```

**Benefits**:

- Simpler configuration (no target cluster needed)
- Faster deployment (no recovery infrastructure)
- Lower resource usage
- Ideal for backup-only scenarios

---

### 2. Connected Component

**Use Case**: For connected component UI integration where BRS connection setup is needed for both backup and recovery clusters. DSC is deployed on both clusters, protection groups are configured, and backups can be triggered, but recovery operations are not performed.

**What Gets Deployed**:

- ✅ Data Source Connector (DSC) via Helm on source cluster
- ✅ Data Source Connector (DSC) via Helm on target cluster
- ✅ Cluster source registration with BRS
- ✅ Target cluster registration with BRS (required)
- ✅ Protection groups for backup
- ✅ Backup operations (if protection groups configured)
- ✅ Security group rules (if VPC)
- ✅ BRS agent service account and RBAC on both clusters

**What's NOT Deployed**:

- ❌ Recovery resources
- ❌ Backup run polling for recovery
- ❌ Snapshot discovery for recovery

**Configuration**:

```hcl
module "backup_recovery" {
  source = "terraform-ibm-modules/iks-ocp-backup-recovery/ibm"

  deployment_mode = "connected_component"

  # Source cluster
  cluster_id                = "source-cluster-id"
  cluster_resource_group_id = "source-rg-id"
  brs_connection_name       = "source-connection"

  # Target cluster (REQUIRED for connected_component mode)
  target_cluster_id                = "target-cluster-id"
  target_cluster_resource_group_id = "target-rg-id"
  target_brs_connection_name       = "target-connection"

  # Protection groups can be configured
  enable_auto_protect      = true
  auto_protect_policy_name = "daily-retention"

  # Or use granular protection groups
  protection_groups = [{
    name        = "production-backup"
    policy_name = "daily-retention"
    objects     = [{ name = "production-namespace" }]
  }]
}
```

**Benefits**:

- Both clusters are registered and ready for operations
- Protection groups configured for backup operations
- Ideal for UI-driven workflows where recovery is managed separately
- Connection can be reused by other components
- Backups can be triggered without recovery overhead

---

### 3. Full Backup and Recovery

**Use Case**: Complete end-to-end validation scenario. Deploys everything including DSC, registrations, protection groups, triggers on-demand backup, waits for completion, and executes recovery.

**What Gets Deployed**:

- ✅ Data Source Connector (DSC) via Helm
- ✅ Cluster source registration with BRS
- ✅ Target cluster registration (if cross-cluster recovery)
- ✅ Protection groups for backup
- ✅ On-demand backup trigger
- ✅ Backup run polling and wait
- ✅ Recovery operations (if `enable_recovery = true`)
- ✅ Security group rules (if VPC)
- ✅ BRS agent service account and RBAC

**Configuration**:

```hcl
module "backup_recovery" {
  source = "terraform-ibm-modules/iks-ocp-backup-recovery/ibm"

  deployment_mode = "full_backup_recovery"

  # Source cluster
  cluster_id                = "source-cluster-id"
  cluster_resource_group_id = "source-rg-id"
  brs_connection_name       = "source-connection"

  # Protection groups
  enable_auto_protect      = true
  auto_protect_policy_name = "daily-retention"

  # Recovery configuration
  enable_recovery = true
  recovery_mode   = "same-cluster"  # or "cross-cluster"

  # For cross-cluster recovery
  target_cluster_id                = "target-cluster-id"
  target_cluster_resource_group_id = "target-rg-id"
  target_brs_connection_name       = "target-connection"

  # Recovery operations
  recoveries = [{
    name                = "restore-production"
    snapshot_id         = "auto"  # Uses latest snapshot
    target_namespace    = "production-restored"
    source_namespace    = "production"
  }]
}
```

**Benefits**:

- Complete validation of backup and recovery workflow
- Production-ready setup
- Automated end-to-end testing
- Ideal for direct DA usage

---

## Deployment Mode Comparison

| Feature              | backup_only | connected_component | full_backup_recovery  |
| -------------------- | ----------- | ------------------- | --------------------- |
| DSC Installation     | ✅          | ✅ (both clusters)  | ✅                    |
| Source Registration  | ✅          | ✅                  | ✅                    |
| Target Registration  | ❌          | ✅ (required)       | ✅ (if cross-cluster) |
| Protection Groups    | ✅          | ✅                  | ✅                    |
| Backup Operations    | ✅          | ✅                  | ✅                    |
| Recovery Support     | ❌          | ❌                  | ✅ (optional)         |
| Backup Run Polling   | ❌          | ❌                  | ✅                    |
| Snapshot Discovery   | ❌          | ❌                  | ✅                    |
| Security Group Rules | ✅          | ✅ (both clusters)  | ✅                    |
| BRS Agent RBAC       | ✅          | ✅ (both clusters)  | ✅                    |
| Connection Setup     | ✅          | ✅ (both clusters)  | ✅                    |

---

## Migration Between Modes

### From Connected Component to Backup Only

1. Update `deployment_mode` to `"backup_only"`
2. Add protection groups or enable auto-protect
3. Apply changes

```hcl
# Before
deployment_mode = "connected_component"

# After
deployment_mode         = "backup_only"
enable_auto_protect     = true
auto_protect_policy_name = "daily-retention"
```

### From Backup Only to Full Backup and Recovery

1. Update `deployment_mode` to `"full_backup_recovery"`
2. Set `enable_recovery = true`
3. Configure target cluster (if cross-cluster)
4. Add recovery operations
5. Apply changes

```hcl
# Before
deployment_mode = "backup_only"

# After
deployment_mode = "full_backup_recovery"
enable_recovery = true
recovery_mode   = "same-cluster"
recoveries      = [...]
```

### From Connected Component to Full Backup and Recovery

1. Update `deployment_mode` to `"full_backup_recovery"`
2. Add protection groups or enable auto-protect
3. Set `enable_recovery = true` (optional)
4. Apply changes

```hcl
# Before
deployment_mode = "connected_component"

# After
deployment_mode         = "full_backup_recovery"
enable_auto_protect     = true
auto_protect_policy_name = "daily-retention"
enable_recovery         = true
```

---

## Validation Rules

The module includes validation to ensure correct configuration:

1. **Target Cluster Validation**: `target_cluster_id` is required when:
   - `deployment_mode = "connected_component"` OR
   - (`deployment_mode = "full_backup_recovery"` AND `recovery_mode = "cross-cluster"`)

2. **Target Resource Group Validation**: `target_cluster_resource_group_id` is required when:
   - `deployment_mode = "connected_component"` OR
   - (`deployment_mode = "full_backup_recovery"` AND `recovery_mode = "cross-cluster"`)

3. **Recovery Validation**: Recovery is only enabled when:
   - `deployment_mode = "full_backup_recovery"` AND
   - `enable_recovery = true`

4. **Protection Groups**: Created in all deployment modes when configured:
   - `deployment_mode = "backup_only"`
   - `deployment_mode = "connected_component"`
   - `deployment_mode = "full_backup_recovery"`

5. **Backup Run Polling**: Only enabled when:
   - `deployment_mode = "full_backup_recovery"`

6. **Snapshot Discovery**: Only enabled when:
   - `deployment_mode = "full_backup_recovery"`

---

## Outputs Behavior

Outputs adapt based on deployment mode:

- `source_registration_id`: Available in all modes
- `target_registration_id`: `null` in `backup_only` mode
- `protection_group_ids`: Available in all modes when protection groups are configured
- `protection_sources`: Available in all modes when protection groups are configured
- `recovery_ids`: Empty map when recovery is disabled
- `latest_snapshots`: Empty map when recovery is disabled

---

## Best Practices

1. **Start Simple**: Begin with `connected_component` or `backup_only` for initial setup
2. **Test Recovery**: Use `deployment_mode = "full_backup_recovery"` with `enable_recovery = false` first
3. **Gradual Migration**: Move from simpler to more complex modes as needed
4. **Resource Planning**: All modes deploy DSC, ensure cluster has sufficient resources
5. **Network Configuration**: Ensure security groups allow DSC communication in VPC clusters

---

## Troubleshooting

### DSC Not Installing

- Check cluster has sufficient resources (CPU, memory)
- Verify network connectivity to IBM Cloud
- Check Helm chart URI is accessible
- Review cluster logs for pod failures

### Source Registration Failing

- Check BRS connection is established
- Verify API key has correct permissions
- Ensure cluster endpoint is accessible
- Review BRS instance status

### Protection Groups Not Created

- Verify protection group configuration is valid (applies to all modes)
- Check policy names exist in BRS instance
- Review namespace names are correct

### Recovery Not Working

- Confirm `deployment_mode = "full_backup_recovery"`
- Verify `enable_recovery = true`
- Check target cluster is registered (for cross-cluster)
- Ensure backup has completed successfully
- Review snapshot availability

---

## Examples

See the `examples/` directory for complete working examples:

- `examples/kubernetes/` - Backup only deployment for IKS
- `examples/openshift/` - Backup only deployment for ROKS
- `examples/backup-recovery-cross-cluster/` - Full deployment with cross-cluster recovery
