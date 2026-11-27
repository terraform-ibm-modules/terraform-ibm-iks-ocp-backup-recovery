# Moved blocks
#
# Each resource below gained `count` (gated by execution_stage flags), which changes its state
# address to `<name>[0]`. These moved blocks map the old addresses to the new ones so that
# consumers upgrading from a previous version do not have these resources destroyed and recreated.

moved {
  from = kubernetes_namespace_v1.dsc_namespace
  to   = kubernetes_namespace_v1.dsc_namespace[0]
}

moved {
  from = terraform_data.dsc_immutable_values
  to   = terraform_data.dsc_immutable_values[0]
}

moved {
  from = terraform_data.check_existing_registration
  to   = terraform_data.check_existing_registration[0]
}

moved {
  from = terraform_data.purge_stale_dsc_pvc
  to   = terraform_data.purge_stale_dsc_pvc[0]
}

moved {
  from = helm_release.data_source_connector
  to   = helm_release.data_source_connector[0]
}

moved {
  from = kubernetes_service_account_v1.brsagent
  to   = kubernetes_service_account_v1.brsagent[0]
}

moved {
  from = kubernetes_cluster_role_binding_v1.brsagent_admin
  to   = kubernetes_cluster_role_binding_v1.brsagent_admin[0]
}

moved {
  from = kubernetes_secret_v1.brsagent_token
  to   = kubernetes_secret_v1.brsagent_token[0]
}

moved {
  from = time_sleep.wait_for_dsc_stabilization
  to   = time_sleep.wait_for_dsc_stabilization[0]
}

moved {
  from = ibm_backup_recovery_source_registration.source_registration
  to   = ibm_backup_recovery_source_registration.source_registration[0]
}

moved {
  from = terraform_data.brs_source_deregistration_wait
  to   = terraform_data.brs_source_deregistration_wait[0]
}

moved {
  from = terraform_data.wait_before_helm_destroy
  to   = terraform_data.wait_before_helm_destroy[0]
}

moved {
  from = terraform_data.wait_for_source_discovery
  to   = terraform_data.wait_for_source_discovery[0]
}
