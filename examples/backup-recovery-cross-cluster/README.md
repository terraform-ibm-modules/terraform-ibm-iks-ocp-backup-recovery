# Cross-Cluster Backup and Recovery example

<!-- BEGIN SCHEMATICS DEPLOY HOOK -->
<p>
  <a href="https://cloud.ibm.com/schematics/workspaces/create?workspace_name=iks-ocp-backup-recovery-backup-recovery-cross-cluster-example&repository=https://github.com/terraform-ibm-modules/terraform-ibm-iks-ocp-backup-recovery/tree/main/examples/backup-recovery-cross-cluster">
    <img src="https://img.shields.io/badge/Deploy%20with%20IBM%20Cloud%20Schematics-0f62fe?style=flat&logo=ibm&logoColor=white&labelColor=0f62fe" alt="Deploy with IBM Cloud Schematics">
  </a><br>
  ℹ️ Ctrl/Cmd+Click or right-click on the Schematics deploy button to open in a new tab.
</p>
<!-- END SCHEMATICS DEPLOY HOOK -->

This example demonstrates **single-shot backup and recovery** across two Kubernetes clusters using a **single shared BRS instance**.

An example that will provision the following:

- A new resource group, if an existing one is not passed in.
- Two basic VPCs with subnets and public gateways enabled (if creating new clusters).
- Two single zone kubernetes VPC clusters (source and target), if not using existing clusters.
- A new Backup & Recovery instance (if not using an existing one).
- Data source connections to integrate both clusters with the Backup & Recovery service.
- Protection group configuration for the source cluster with immediate backup schedule.
- Optional automatic cross-cluster recovery after backup completion.

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

## Key Features

- **Shared BRS Instance**: Single Backup & Recovery Service instance manages both clusters
- **Immediate Backup Schedule**: 7-minute backup frequency (minimum allowed by BRS API) for quick testing
- **Cross-Cluster Recovery**: Fully functional recovery implementation using BRS API
- **Single-Shot Flow**: Complete backup and recovery in one `terraform apply` when `enable_recovery = true`
- **Flexible Configuration**: Use existing clusters and BRS instances or create new ones

## Prerequisites

- IBM Cloud account with appropriate permissions
- IBM Cloud API key
- Terraform >= 1.9.0
- Sufficient quota for:
  - 2 VPCs (if creating new clusters)
  - 2 Kubernetes clusters (if creating new)
  - 1 Backup & Recovery Service instance (if creating new)

## Usage

### Basic Usage

```hcl
ibmcloud_api_key = "YOUR_API_KEY"  # pragma: allowlist secret
prefix           = "bkp-rcv"
region           = "us-south"
```

### Using Existing Resources

```hcl
ibmcloud_api_key = "YOUR_API_KEY"  # pragma: allowlist secret
prefix           = "bkp-rcv"
region           = "us-south"

# Use existing clusters
source_cluster_name_id = "existing-source-cluster"
target_cluster_name_id = "existing-target-cluster"

# Use existing BRS instance
existing_brs_instance_crn = "crn:v1:bluemix:public:backup-recovery:us-south:a/abc:def::"
```

### Enable Automatic Recovery

```hcl
ibmcloud_api_key = "YOUR_API_KEY"  # pragma: allowlist secret
prefix           = "bkp-rcv"
region           = "us-south"

# Enable automatic recovery after backup
enable_recovery            = true
recovery_mode              = "cross-cluster"
wait_for_backup_completion = "5m"
```

## Deployment Steps

1. **Initialize Terraform**

   ```bash
   terraform init
   ```

2. **Review the Plan**

   ```bash
   terraform plan
   ```

3. **Apply Configuration**

   ```bash
   terraform apply
   ```

   **Expected Duration:**
   - New clusters: 45-60 minutes
   - Existing clusters: 30-45 minutes
   - With recovery enabled: Add 30+ minutes for backup/recovery

4. **Verify Deployment**
   ```bash
   terraform output
   ```

## Testing Scenarios

### Scenario 1: Backup Only

Test backup functionality without recovery:

```hcl
enable_recovery = false
```

### Scenario 2: Cross-Cluster Recovery

Test recovery to target cluster:

```hcl
enable_recovery = true
recovery_mode   = "cross-cluster"
```

### Scenario 3: Same-Cluster Recovery

Test recovery within source cluster:

```hcl
enable_recovery = true
recovery_mode   = "same-cluster"
```

## Verification

### Check Backup Status

```bash
# List protection group runs
ibmcloud backup-recovery protection-group-runs list \
  --protection-group-id $(terraform output -json source_protection_group_ids | jq -r '.[0]') \
  --instance-id $(terraform output -raw brs_instance_guid)
```

### Verify Recovery (if enabled)

```bash
# Configure kubectl for target cluster
ibmcloud ks cluster config --cluster $(terraform output -raw target_cluster_id)

# Check recovered namespace
kubectl get namespaces

# Verify recovered workload
kubectl get all -n $(terraform output -raw source_workload_namespace)
```

## Important Notes

- **Backup Schedule**: Uses 7-minute frequency (minimum allowed by BRS API) for quick testing
- **Recovery Implementation**: Uses BRS API directly via shell script for cross-cluster recovery
- **Shared BRS Instance**: Created independently before cluster modules to avoid dependency cycles
- **Active Polling**: Module actively polls for backup completion (up to 45 minutes by default)

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

This will delete:

- Both clusters (if created by this example)
- BRS instance (if created by this example)
- All backups and snapshots
- VPC infrastructure (if created)

## Cost Estimation

Approximate monthly costs (us-south region):

| Resource                  | Quantity   | Est. Cost/Month |
| ------------------------- | ---------- | --------------- |
| IKS Cluster (bx2.4x16 x2) | 2 clusters | ~$300           |
| BRS Instance              | 1          | ~$100           |
| VPC Infrastructure        | 2 VPCs     | ~$20            |
| **Total**                 |            | **~$420/month** |

**Cost Optimization:**

- Use existing clusters to save ~$300/month
- Use existing BRS instance to save ~$100/month
- Destroy resources when not testing

## Additional Resources

- [Main Module README](../../README.md)
- [Recovery Implementation Guide](../../RECOVERY_IMPLEMENTATION.md)
- [Protection Group Configuration Guide](../../ProtectionGroup.md)
- [IBM Backup Recovery Documentation](https://cloud.ibm.com/docs/backup-recovery)
