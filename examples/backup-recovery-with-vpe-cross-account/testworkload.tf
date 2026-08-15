##############################################################################
# Test Workload — brs-testing-10g
#
# Creates the namespace + StatefulSet + headless Service that the protection
# group will back up.  The StatefulSet uses a 20 Gi VPC Block PVC so that
# the backup contains real persistent-volume data.
#
# The namespace name ("brs-testing-10g") is used as the object name in the
# protection group, so BRS knows exactly which namespace to protect.
#
# Ordering:
#   cluster kubeconfig available  →  namespace  →  StatefulSet / Service
#   workload ready                →  module.iks_backup_only (via depends_on)
##############################################################################

# ── Namespace ──────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "brs_testing" {
  metadata {
    name = var.workload_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "backup-enabled"               = "true"
    }
  }

  depends_on = [data.ibm_container_cluster_config.cluster_config]
}

# ── Headless Service (required by StatefulSet) ─────────────────────────────

resource "kubernetes_service_v1" "busybox_headless" {
  metadata {
    name      = "busybox-headless"
    namespace = kubernetes_namespace_v1.brs_testing.metadata[0].name
  }

  spec {
    selector = {
      app = "busybox-app-vpc-block-pvc"
    }
    cluster_ip = "None"
  }
}

# ── StatefulSet with 20 Gi VPC Block PVC ──────────────────────────────────

resource "kubernetes_stateful_set_v1" "brs_testing" {
  #checkov:skip=CKV_K8S_8:Test workload - liveness probe not required
  #checkov:skip=CKV_K8S_9:Test workload - readiness probe not required
  #checkov:skip=CKV_K8S_28:Test workload - NET_RAW capability not dropped
  #checkov:skip=CKV_K8S_29:Test workload - security context not applied
  #checkov:skip=CKV_K8S_30:Test workload - container security context not applied
  #checkov:skip=CKV_K8S_14:Test workload - using latest tag for simplicity
  #checkov:skip=CKV_K8S_43:Test workload - image digest not used

  metadata {
    name      = "app-with-vpc-block-pvc"
    namespace = kubernetes_namespace_v1.brs_testing.metadata[0].name
    labels = {
      app = "busybox-app-vpc-block-pvc"
    }
  }

  spec {
    service_name = kubernetes_service_v1.busybox_headless.metadata[0].name
    replicas     = 1

    selector {
      match_labels = {
        app = "busybox-app-vpc-block-pvc"
      }
    }

    template {
      metadata {
        labels = {
          app = "busybox-app-vpc-block-pvc"
        }
      }

      spec {
        container {
          name    = "test-app"
          image   = "icr.io/ext/cohesity/busybox:latest"
          command = ["sh", "-c"]
          args = [
            <<-EOT
              echo "Generating 10GB test data...";
              dd if=/dev/zero of=/data/testfile.dat bs=1M count=10240 && sync;
              echo "Data generation complete. Calculating MD5 checksum...";
              md5sum /data/testfile.dat;
              echo "Pod is ready. Sleeping...";
              sleep infinity
            EOT
          ]

          volume_mount {
            name       = "data-storage"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data-storage"
        labels = {
          app = "busybox-app-vpc-block-pvc"
        }
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "ibmc-vpc-block-metro-5iops-tier"

        resources {
          requests = {
            storage = "20Gi"
          }
        }
      }
    }
  }

  wait_for_rollout = false
}
