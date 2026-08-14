##############################################################################
# Outputs
##############################################################################

output "cluster_id" {
  description = "ID of the IKS cluster being protected."
  value       = local.cluster_id
}

output "source_registration_id" {
  description = "ID of the registered Kubernetes source."
  value       = module.backup_recover_protect_iks.source_registration_id
}

output "brs_instance_crn" {
  description = "CRN of the Backup & Recovery Service instance."
  value       = module.backup_recover_protect_iks.brs_instance_crn
}

output "brs_instance_guid" {
  description = "GUID of the Backup & Recovery Service instance."
  value       = module.backup_recover_protect_iks.brs_instance_guid
}

output "brs_instance_url" {
  description = "Public API endpoint URL for the BRS instance."
  value       = module.backup_recover_protect_iks.brs_instance_url
}

output "brs_private_hostname" {
  description = "BRS private hostname that should resolve to the VPEG reserved IP inside the cluster VPC. Run 'getent hosts <value>' from inside a DSC pod to verify VPE routing. Only relevant when create_brs_vpe = true."
  value       = var.create_brs_vpe && !var.classic_cluster ? "${module.backup_recover_protect_iks.brs_instance_guid}.private.${var.region}.backup-recovery.cloud.ibm.com" : null
}

output "brs_vpe_ips" {
  description = "Map of VPEG name → reserved IP list. Populated only when create_brs_vpe = true and cluster is VPC-based; empty map otherwise."
  value = local.brs_vpe_active ? {
    (local.brs_vpe_name) = values(ibm_is_subnet_reserved_ip.brs_vpe_ip)[*].address
  } : {}
}

output "protection_group_ids" {
  description = "Map of protection group names to their IDs."
  value       = module.backup_recover_protect_iks.protection_group_ids
}
