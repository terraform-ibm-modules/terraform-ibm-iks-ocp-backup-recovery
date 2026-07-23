output "region" {
  value       = var.region
  description = "Region where resources are deployed."
}

output "brs_instance_crn" {
  value       = module.source_connection.brs_instance_crn
  description = "CRN of the Backup and Recovery Service instance."
}

output "source_connection_name" {
  value       = module.source_connection.connection_name
  description = "Name of the source BRS connection."
  sensitive   = true
}

output "target_connection_name" {
  value       = module.target_connection.connection_name
  description = "Name of the target BRS connection."
  sensitive   = true
}
