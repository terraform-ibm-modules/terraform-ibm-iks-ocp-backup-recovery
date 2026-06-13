##############################################################################
# Outputs
##############################################################################

output "source_registration_id" {
  description = "ID of the registered Kubernetes source. Null if source registration is skipped."
  value       = length(ibm_backup_recovery_source_registration.source_registration) > 0 ? ibm_backup_recovery_source_registration.source_registration[0].id : null
}

output "brs_instance_crn" {
  description = "CRN of the Backup & Recovery Service instance"
  value       = module.backup_recovery_instance.brs_instance_crn
}

output "brs_instance_guid" {
  description = "GUID of the Backup & Recovery Service instance"
  value       = local.brs_instance_guid
}

output "brs_tenant_id" {
  description = "Tenant ID of the Backup & Recovery Service instance"
  value       = local.brs_tenant_id
}

output "connection_id" {
  description = "ID of the data source connection to the Backup & Recovery Service instance"
  value       = local.connection_id
}

output "protection_group_ids" {
  description = "Map of protection group names to their IDs. Empty if protection groups are not deployed."
  value       = { for k, v in ibm_backup_recovery_protection_group.protection_group : k => v.id }
}

output "auto_protect_group_id" {
  description = "ID of the auto-protect protection group. Null if auto-protect is not enabled."
  value       = var.enable_auto_protect && var.auto_protect_policy_name != null && length(ibm_backup_recovery_source_registration.source_registration) > 0 ? try(ibm_backup_recovery_source_registration.source_registration[0].kubernetes_params[0].auto_protect_config[0].protection_group_id, null) : null
}

output "protection_sources" {
  description = "List of protection sources. Null if protection groups are not deployed."
  value       = length(data.ibm_backup_recovery_protection_sources.sources) > 0 ? data.ibm_backup_recovery_protection_sources.sources[0] : null
}

output "recovery_ids" {
  description = "Map of recovery operation names to their IDs. Empty if recovery is not enabled."
  value       = { for k, v in ibm_backup_recovery.recover_snapshot : k => v.id }
}

output "recovery_status" {
  description = "Map of recovery operation names to their status information. Empty if `var.enable_recovery` is `false`."
  value = {
    for k, v in ibm_backup_recovery.recover_snapshot : k => {
      id     = v.id
      status = v.status
      name   = v.name
    }
  }
}

output "latest_snapshots" {
  description = "Map of protection group names to the most recent successful snapshot ID per protection group. Populated only when `var.enable_recovery` is `true`, because snapshot discovery relies on the backup-polling infrastructure (`terraform_data.wait_for_backup_run` and `data.ibm_backup_recovery_protection_group_runs`) that is activated by that flag. Use the snapshot IDs from this output as explicit `snapshot_id` values in a recovery's `kubernetes_params.objects` to target a specific backup rather than always recovering the latest."
  value       = local.latest_snapshots
}

output "target_cluster_id" {
  description = "Target cluster ID for recovery operations. Same as source cluster for `same-cluster` recovery mode."
  value       = local.target_cluster_id
}

output "backup_runs_summary" {
  description = "Summary of backup runs per protection group. Shows run count and latest run status. Empty if `var.enable_recovery` is `false`."
  value = {
    for pg_name, runs in data.ibm_backup_recovery_protection_group_runs.backup_runs : pg_name => {
      total_runs          = length(try(runs.runs, []))
      latest_run_id       = try(runs.runs[0].id, null)
      latest_status       = try(runs.runs[0].status, null)
      latest_snapshot_id  = try(runs.runs[0].local_backup_info[0].snapshot_info[0].snapshot_id, null)
      polled_backup_ready = contains(keys(terraform_data.wait_for_backup_run), pg_name)
    }
  }
}

output "brs_instance_url" {
  description = "Endpoint URL for the BRS instance, derived from the IBM Cloud resource extensions. Correct for both staging and production environments."
  value       = "https://${local.backup_recovery_instance_url}"
}

output "brs_tags" {
  description = "BRS tags that should be added to the cluster to prevent tag drift. Include these in your cluster's tags input."
  value       = ["brs-region:${local.brs_instance_region}", "brs-guid:${local.brs_instance_guid}"]
}
