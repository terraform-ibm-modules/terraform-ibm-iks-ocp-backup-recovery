##############################################################################
# Outputs
##############################################################################

output "source_cluster_id" {
  description = "ID of the source cluster."
  value       = local.source_cluster_id
}

output "target_cluster_id" {
  description = "ID of the target cluster."
  value       = local.target_cluster_id
}

output "brs_instance_crn" {
  description = "CRN of the shared Backup & Recovery Service instance."
  value       = module.source_backup_recovery.brs_instance_crn
}

output "brs_instance_guid" {
  description = "GUID of the shared Backup & Recovery Service instance."
  value       = module.source_backup_recovery.brs_instance_guid
}

output "brs_instance_url" {
  description = "Public API endpoint URL for the BRS instance."
  value       = "https://${module.source_backup_recovery.brs_instance_guid}.${var.region}.backup-recovery.cloud.ibm.com"
}

output "brs_private_hostname" {
  description = "BRS private hostname that should resolve to the VPEG reserved IP inside each cluster VPC. Run 'getent hosts <value>' from inside a DSC pod to verify VPE routing."
  value       = "${module.source_backup_recovery.brs_instance_guid}.private.${var.region}.backup-recovery.cloud.ibm.com"
}

output "source_vpe_ips" {
  description = "Map of VPEG name → list of reserved IP objects bound to each subnet in the source VPC."
  value       = module.source_backup_recovery.brs_vpe_ips
}

output "target_vpe_ips" {
  description = "Map of VPEG name → list of reserved IP objects bound to each subnet in the target VPC."
  value       = module.target_backup_recovery.brs_vpe_ips
}

output "source_connection_id" {
  description = "Data-source connection ID for the source cluster."
  value       = module.source_backup_recovery.connection_id
  sensitive   = true
}

output "target_connection_id" {
  description = "Data-source connection ID for the target cluster."
  value       = module.target_backup_recovery.connection_id
  sensitive   = true
}

output "source_registration_id" {
  description = "Source registration ID for the source cluster."
  value       = module.source_backup_recovery.source_registration_id
}

output "target_registration_id" {
  description = "Source registration ID for the target cluster."
  value       = module.target_backup_recovery.source_registration_id
}

output "source_protection_group_ids" {
  description = "Map of protection group names to their IDs on the source cluster."
  value       = module.source_backup_recovery.protection_group_ids
}

output "source_workload_namespace" {
  description = "Name of the test workload namespace on the source cluster."
  value       = local.source_namespace
}

output "recovery_ids" {
  description = "Recovery operation IDs (empty if enable_recovery is false)."
  value       = module.source_backup_recovery.recovery_ids
}

output "recovery_status" {
  description = "Recovery operation status (empty if enable_recovery is false)."
  value       = module.source_backup_recovery.recovery_status
}

output "latest_snapshots" {
  description = "Latest snapshot IDs per protection group (empty if enable_recovery is false)."
  value       = module.source_backup_recovery.latest_snapshots
}

output "backup_runs_summary" {
  description = "Summary of backup runs per protection group (empty if enable_recovery is false)."
  value       = module.source_backup_recovery.backup_runs_summary
}

output "cross_cluster_recovery_status" {
  description = "Status of the cross-cluster recovery operation."
  value       = var.enable_recovery ? "Recovery triggered via API — check BRS UI for detailed status" : "Recovery disabled (enable_recovery = false)"
}

output "recovery_command_example" {
  description = "Example command to manually trigger cross-cluster recovery from the command line."
  value = var.enable_recovery ? format(
    "%s '%s' '%s' 'public' '%s' '%s' '%s' 'latest' '$IBMCLOUD_API_KEY' 'manual-recovery' '/tmp'",
    "${path.module}/../../scripts/trigger_cross_cluster_recovery.sh",
    "https://${module.source_backup_recovery.brs_instance_guid}.${var.region}.backup-recovery.cloud.ibm.com",
    module.source_backup_recovery.brs_tenant_id,
    module.source_backup_recovery.brs_instance_guid,
    split("::", module.source_backup_recovery.protection_group_ids["${var.prefix}-source-pg"])[1],
    split("::", module.target_backup_recovery.source_registration_id)[1]
  ) : "Recovery disabled"
  sensitive = false
}
