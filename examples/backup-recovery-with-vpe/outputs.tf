output "cluster_id" {
  description = "ID of the IKS cluster being protected."
  value       = local.cluster_id
}

output "brs_instance_crn" {
  description = "CRN of the Backup and Recovery Service instance."
  value       = module.backup_recovery.brs_instance_crn
}

output "brs_connection_id" {
  description = "ID of the BRS data-source connection."
  value       = module.backup_recovery.connection_id
  sensitive   = true
}

output "brs_private_hostname" {
  description = "BRS private hostname that should resolve to the VPEG reserved IP inside the cluster VPC. Run 'getent hosts <value>' from inside a DSC pod to verify VPE routing."
  value       = "${module.backup_recovery.brs_instance_guid}.private.${var.region}.backup-recovery.cloud.ibm.com"
}

output "brs_vpe_ips" {
  description = "Map of VPEG name to reserved IP list. Each entry contains the private IP addresses bound to each subnet zone."
  value = var.create_brs_vpe ? {
    (local.brs_vpe_name) = values(ibm_is_subnet_reserved_ip.brs_vpe_ip)[*].address
  } : {}
}
