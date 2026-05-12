# Cross-Cluster Backup and Recovery Example

<!-- BEGIN SCHEMATICS DEPLOY HOOK -->
<p>
  <a href="https://cloud.ibm.com/schematics/workspaces/create?workspace_name=iks-ocp-backup-recovery-backup-recovery-cross-cluster-example&repository=https://github.com/terraform-ibm-modules/terraform-ibm-iks-ocp-backup-recovery/tree/main/examples/backup-recovery-cross-cluster">
    <img src="https://img.shields.io/badge/Deploy%20with%20IBM%20Cloud%20Schematics-0f62fe?style=flat&logo=ibm&logoColor=white&labelColor=0f62fe" alt="Deploy with IBM Cloud Schematics">
  </a><br>
  ℹ️ Ctrl/Cmd+Click or right-click on the Schematics deploy button to open in a new tab.
</p>
<!-- END SCHEMATICS DEPLOY HOOK -->

This example demonstrates **single-shot backup and recovery** across two Kubernetes clusters using a **single shared BRS instance**.

## ✅ Working Cross-Cluster Recovery Solution

This example includes a **fully functional cross-cluster recovery implementation** using the BRS API directly via a shell script ([`trigger_cross_cluster_recovery.sh`](../../scripts/trigger_cross_cluster_recovery.sh)). The IBM Terraform provider doesn't yet expose the necessary parameters (`recoverNamespaceParams`, `recoveryTargetConfig`, etc.) for specifying a target cluster, so we use the API directly.

**Key Achievement**: Successfully identified and implemented the correct API payload structure by analyzing UI-generated recovery requests.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│          Shared BRS Instance (Created First)                 │
│  - Single instance for all backup/recovery operations       │
│  - Multiple source registrations (one per cluster)          │
└─────────────────────────────────────────────────────────────┘
                    │                    │
                    │                    │
        ┌───────────▼──────────┐    ┌───▼──────────────┐
        │  Source Cluster      │    │  Target Cluster  │
        │  - DSC Installed     │    │  - DSC Installed │
        │  - Backup Enabled    │    │  - Recovery Dest │
        │  - Protection Groups │    │                  │
        └──────────────────────┘    └──────────────────┘
```

**Key Design Decisions**:

- The BRS instance is created as a separate module **before** the cluster modules. This avoids Terraform dependency cycles where computed values (like BRS CRN from one module) would be passed to another module's `existing_brs_instance_crn` parameter, causing count/for_each evaluation issues.
- **Immediate Backup Schedule**: Uses 1-minute frequency for backup jobs to ensure snapshots are available quickly for cross-cluster recovery testing. This is critical because recovery operations depend on completed backup snapshots.

## What This Example Does

1. **Creates Infrastructure** (if not using existing clusters):
   - Two VPCs with subnets and public gateways
   - Source Kubernetes cluster
   - Target Kubernetes cluster

2. **Provisions Shared BRS Instance First**:
   - Creates one Backup & Recovery Service instance independently
   - This instance will be referenced by both cluster modules
   - Avoids dependency cycles in Terraform

3. **Configures Source Cluster**:
   - Installs Data Source Connector (DSC)
   - Registers cluster with shared BRS instance
   - Creates protection group for backup
   - Deploys sample workload for testing

4. **Configures Target Cluster**:
   - Installs Data Source Connector (DSC)
   - Registers cluster with **same** shared BRS instance
   - Ready to receive recovered workloads

5. **Executes Single-Shot Backup + Recovery** (when `enable_recovery = true`):
   - Backs up source cluster workloads with **7-minute frequency** (fastest allowed by BRS API)
   - Actively polls for backup completion (using `wait_for_backup_run.sh` script)
   - Automatically recovers to target cluster once snapshot is available
   - All in one `terraform apply`

## Prerequisites

- IBM Cloud account with appropriate permissions
- IBM Cloud API key
- Terraform >= 1.9.0
- Sufficient quota for:
  - 2 VPCs (if creating new clusters)
  - 2 Kubernetes clusters (if creating new)
  - 1 Backup & Recovery Service instance (if creating new)

## Usage

### Step 1: Configure Variables

Copy the example tfvars file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
ibmcloud_api_key = "YOUR_API_KEY"  # pragma: allowlist secret
prefix           = "my-test"
region           = "us-south"

# Optional: Use existing clusters
source_cluster_name_id = null  # or "existing-source-cluster"
target_cluster_name_id = null  # or "existing-target-cluster"

# Optional: Use existing BRS instance
existing_brs_instance_crn = null  # or "crn:v1:..."

# Recovery configuration
enable_recovery            = true
recovery_mode              = "cross-cluster"
wait_for_backup_completion = 5  # Initial wait before polling (polling handles the rest)
```

### Step 2: Initialize Terraform

```bash
terraform init
```

### Step 3: Plan Deployment

```bash
terraform plan
```

Review the plan to ensure:

- Correct number of resources will be created
- BRS instance is shared (only one created)
- Both clusters will be registered with the same BRS instance

### Step 4: Deploy

```bash
terraform apply
```

This will:

1. Create infrastructure (if needed)
2. Deploy source and target clusters (if needed)
3. Create single BRS instance (if needed)
4. Install DSC on both clusters
5. Register both clusters with the BRS instance
6. Create protection group on source cluster
7. Deploy test workload on source cluster
8. If `enable_recovery = true`:
   - Wait for initial backup to complete
   - Automatically recover to target cluster

**Expected Duration:**

- New clusters: 45-60 minutes
- Existing clusters: 30-45 minutes
- With recovery enabled: Add 30+ minutes for backup/recovery

### Step 5: Verify Deployment

Check the outputs:

```bash
terraform output
```

Key outputs to verify:

- `brs_instance_crn` - Single BRS instance CRN
- `source_connection_id` - Source cluster connection
- `target_connection_id` - Target cluster connection
- `recovery_status` - Recovery operation status (if enabled)
- `latest_snapshots` - Available backup snapshots

### Step 6: Verify Recovery (if enabled)

Check target cluster for recovered workload:

```bash
# Get target cluster config
ibmcloud ks cluster config --cluster $(terraform output -raw target_cluster_id)

# List namespaces (should see recovered namespace)
kubectl get namespaces

# Check recovered workload
kubectl get all -n $(terraform output -raw source_workload_namespace)
```

## Testing Scenarios

### Scenario 1: Backup Only (No Recovery)

Test backup functionality without recovery:

```hcl
# terraform.tfvars
enable_recovery = false
```

```bash
terraform apply
```

Verify backup:

```bash
# Check protection group runs
ibmcloud backup-recovery protection-group-runs list \
  --protection-group-id $(terraform output -json source_protection_group_ids | jq -r '.[0]') \
  --instance-id $(terraform output -raw brs_instance_guid)
```

### Scenario 2: Cross-Cluster Recovery via API

Test the working cross-cluster recovery implementation:

```hcl
# terraform.tfvars
enable_recovery            = true
wait_for_backup_completion = 5  # Initial wait, then active polling
```

```bash
terraform apply
```

The recovery will be triggered automatically via the [`trigger_cross_cluster_recovery.sh`](../../scripts/trigger_cross_cluster_recovery.sh) script, which uses the correct BRS API payload structure:

```json
{
  "name": "recovery-name",
  "snapshotEnvironment": "kKubernetes",
  "kubernetesParams": {
    "recoveryAction": "RecoverNamespaces",
    "objects": [{ "snapshotId": "...", "protectionGroupId": "..." }],
    "recoverNamespaceParams": {
      "targetEnvironment": "kKubernetes",
      "kubernetesTargetParams": {
        "objects": [{ "snapshotId": "...", "protectionGroupId": "..." }],
        "recoveryTargetConfig": {
          "recoverToNewSource": true,
          "newSourceConfig": {
            "source": { "id": 2441 }
          }
        },
        "renameRecoveredNamespacesParams": {
          "prefix": "restored-"
        }
      }
    }
  }
}
```

**Key Structure Elements:**

- `recoverNamespaceParams` wrapper (critical - was missing in initial attempts)
- `recoveryTargetConfig.newSourceConfig.source.id` specifies target cluster
- Namespace prefix to avoid conflicts

Verify recovery in BRS UI or via API:

```bash
# Check recovery status
curl -s "https://$(terraform output -raw brs_instance_guid).$(terraform output -raw region).backup-recovery.cloud.ibm.com/v2/data-protect/recoveries" \
  -H "Authorization: Bearer $IAM_TOKEN" \
  -H "X-IBM-Tenant-Id: $(terraform output -raw brs_tenant_id)" | jq '.recoveries[] | select(.name | contains("restore"))'
```

### Scenario 3: Manual Cross-Cluster Recovery

You can also trigger recovery manually using the script:

```bash
# Get the example command from Terraform output
terraform output recovery_command_example

# Or construct manually:
../../scripts/trigger_cross_cluster_recovery.sh \
  'https://INSTANCE_GUID.REGION.backup-recovery.cloud.ibm.com' \
  'TENANT_ID/' \
  'public' \
  'INSTANCE_GUID' \
  'PROTECTION_GROUP_ID' \
  'TARGET_SOURCE_ID' \
  'SNAPSHOT_ID_OR_latest' \
  "$IBMCLOUD_API_KEY" \
  'my-manual-recovery' \
  '/tmp'
```

### Scenario 2: Same-Cluster Recovery

Test recovery within the source cluster:

```hcl
# terraform.tfvars
enable_recovery = true
recovery_mode   = "same-cluster"
```

```bash
terraform apply
```

### Scenario 3: Cross-Cluster Recovery

Test recovery to target cluster (default):

```hcl
# terraform.tfvars
enable_recovery = true
recovery_mode   = "cross-cluster"
```

```bash
terraform apply
```

### Scenario 4: Using Existing Clusters

Test with pre-existing clusters:

```hcl
# terraform.tfvars
source_cluster_name_id = "my-existing-source"
target_cluster_name_id = "my-existing-target"
```

```bash
terraform apply
```

### Scenario 5: Using Existing BRS Instance

Test with pre-existing BRS instance:

```hcl
# terraform.tfvars
existing_brs_instance_crn = "crn:v1:bluemix:public:backup-recovery:us-south:a/abc:def::"
```

```bash
terraform apply
```

## Backup Schedule Configuration

### Immediate Backup (Current Configuration)

The example uses **7-minute backup frequency** for immediate backup job execution:

```hcl
schedule = {
  unit = "Minutes"
  minute_schedule = {
    frequency = 7  # Minimum allowed by BRS API
  }
}
```

**Why 7-minute frequency for cross-cluster?**

- ✅ **Recovery depends on snapshots**: You cannot recover until a backup completes
- ✅ **Fastest allowed**: 7 minutes is the minimum frequency supported by BRS API
- ✅ **Low RPO**: Maximum 7 minutes of data loss
- ✅ **Ideal for demos/testing**: Quick validation of backup+recovery flow

**BRS API Constraint**: The Backup & Recovery Service requires minimum frequencies of:

- **Minutes**: >= 7 minutes
- **Hours**: >= 1 hour
- **Days**: >= 1 day

**Alternative Schedules:**

For production use, consider adjusting based on your needs:

```hcl
# Hourly backups (balanced)
schedule = {
  unit = "Minutes"
  minute_schedule = {
    frequency = 60  # Every hour
  }
}

# Daily backups (cost-effective)
schedule = {
  unit = "Days"
  day_schedule = {
    frequency = 1  # Once per day
  }
}
```

### Understanding Backup Job Triggers

**Important:** Backup jobs are triggered by the **schedule**, NOT by auto-protect:

| Feature              | Purpose                                          | Triggers Backup? |
| -------------------- | ------------------------------------------------ | ---------------- |
| **Auto-Protect**     | Automatically discovers and registers namespaces | ❌ No            |
| **Backup Schedule**  | Defines when backup jobs run                     | ✅ Yes           |
| **Protection Group** | Defines what to backup                           | ❌ No            |

**Flow:**

1. Protection Group created → Defines backup scope
2. Schedule triggers → Backup job starts (based on frequency)
3. Backup completes → Snapshot available for recovery

## Troubleshooting

### Issue: No Snapshots Found

**Error:**

```
No backup snapshots found. Recovery cannot proceed without completed backups.
```

**Solutions:**

1. The module uses active polling (up to 45 minutes by default). If backups are taking longer, check:

   ```bash
   # Check if backup job has started
   kubectl get pods -n ibm-brs-data-source-connector
   ```

2. Check backup status:

   ```bash
   ibmcloud backup-recovery protection-group-runs list \
     --protection-group-id <pg-id> \
     --instance-id <brs-guid>
   ```

3. Verify DSC is running:
   ```bash
   kubectl get pods -n ibm-brs-data-source-connector
   ```

### Issue: Target Cluster Not Registered

**Error:**

```
Target cluster not found in protection sources
```

**Solution:**
Ensure target cluster module completes before recovery:

- Check `target_connection_id` output is populated
- Verify DSC pods are running on target cluster
- Wait a few minutes for BRS to discover target cluster

### Issue: Recovery Fails

**Error:**

```
Recovery operation failed
```

**Solutions:**

1. Check recovery status:

   ```bash
   terraform output recovery_status
   ```

2. View BRS logs:

   ```bash
   ibmcloud backup-recovery recovery get \
     --recovery-id <recovery-id> \
     --instance-id <brs-guid>
   ```

3. Verify target cluster has sufficient resources:
   ```bash
   kubectl top nodes
   kubectl describe nodes
   ```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Note:** This will:

- Delete both clusters (if created by this example)
- Delete BRS instance (if created by this example)
- Delete all backups and snapshots
- Delete VPC infrastructure (if created)

## Cost Estimation

Approximate monthly costs (us-south region):

| Resource                  | Quantity   | Est. Cost/Month |
| ------------------------- | ---------- | --------------- |
| IKS Cluster (bx2.4x16 x2) | 2 clusters | ~$300           |
| BRS Instance              | 1          | ~$100           |
| VPC Infrastructure        | 2 VPCs     | ~$20            |
| **Total**                 |            | **~$420/month** |

**Cost Optimization Tips:**

- Use existing clusters to save ~$300/month
- Use existing BRS instance to save ~$100/month
- Destroy resources when not testing
- Use smaller cluster flavors for testing

## Key Differences from Main Module

This example differs from the main module in:

1. **Dual Cluster Setup**: Creates/manages two clusters instead of one
2. **Provider Aliases**: Uses separate providers for source and target clusters
3. **Test Workload**: Includes sample deployment for testing
4. **Simplified Configuration**: Uses defaults suitable for testing

The **recovery logic is identical** to what the main module provides - this example just demonstrates it in a complete, runnable scenario.

## Integration with Deployable Architecture

This example mirrors the logic used in the deployable architecture. The only differences are:

- **Input Method**: Example uses `terraform.tfvars`, DA uses catalog inputs
- **Cluster Management**: Example can create clusters, DA expects existing clusters
- **Scope**: Example is self-contained, DA integrates with broader infrastructure

The **backup and recovery flow is identical** between this example and the DA.

## Additional Resources

- [Main Module README](../../README.md)
- [Recovery Implementation Guide](../../RECOVERY_IMPLEMENTATION.md)
- [Protection Group Configuration Guide](../../ProtectionGroup.md)
- [IBM Backup Recovery Documentation](https://cloud.ibm.com/docs/backup-recovery)

## Support

For issues or questions:

1. Check the [Troubleshooting](#troubleshooting) section above
2. Review the [Recovery Implementation Guide](../../RECOVERY_IMPLEMENTATION.md)
3. Open an issue in the GitHub repository
