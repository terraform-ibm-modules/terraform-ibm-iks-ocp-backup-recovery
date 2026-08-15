#!/bin/bash

set -e

# Wait for BRS to clean up runtime resources after source deregistration. BRS
# removes the brs-backup-agent-* namespace itself, via the DSC tunnel and the
# brsagent RBAC; this script only observes (every kubectl call is a `get`) so
# terraform does not tear those down while the removal is in flight.
#
# Always exits 0 — an unreachable cluster must not block `terraform destroy` —
# but reports why it could not observe, because a silent skip is
# indistinguishable from success and leaves a namespace that blocks the next
# apply (see check-existing-registration.sh).
#
# Usage:
#   wait_for_namespace_cleanup.sh <dsc_namespace> [max_attempts] [binaries_path]
#
# Environment variables:
#   KUBECONFIG - Path to kubeconfig file created by the terraform provider

DSC_NAMESPACE="${1:-ibm-brs-data-source-connector}"
MAX_ATTEMPTS="${2:-20}"
BINARIES_PATH="${3:-/tmp}"
SLEEP_DURATION=30

# The binaries downloaded by install-binaries are placed in binaries_path (default: /tmp)
export PATH=$PATH:${BINARIES_PATH}

echo "Waiting for BRS-managed resources to be cleaned up..."
echo "DSC Namespace: $DSC_NAMESPACE"
echo "Max attempts: $MAX_ATTEMPTS (checking every ${SLEEP_DURATION}s)"

# Printed whenever this script gives up without confirming the namespace is gone.
# BRS will not retry once the DSC and the brsagent RBAC are destroyed, so the
# operator has to finish the job by hand.
manual_cleanup_notice() {
  echo ""
  echo "================================================================================" >&2
  echo "WARNING: could not confirm that BRS removed its agent namespace." >&2
  echo "" >&2
  echo "If a 'brs-backup-agent-*' namespace is left on the cluster, the next apply will" >&2
  echo "fail in check-existing-registration.sh. Remove it manually:" >&2
  echo "" >&2
  echo "    kubectl get ns | grep brs-backup-agent-" >&2
  echo "    kubectl delete ns <namespace>" >&2
  echo "" >&2
  echo "A namespace stuck in Terminating usually has velero finalizers left behind:" >&2
  echo "" >&2
  echo "    kubectl get backups.velero.io,restores.velero.io -n <namespace>" >&2
  echo "    kubectl patch <resource> -n <namespace> -p '{\"metadata\":{\"finalizers\":null}}' --type=merge" >&2
  echo "================================================================================" >&2
}

# ---------------------------------------------------------------------------
# Preflight — report exactly what is missing instead of skipping silently.
# ---------------------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found on PATH (searched \$PATH and ${BINARIES_PATH})." >&2
  manual_cleanup_notice
  exit 0
fi

if [ -z "${KUBECONFIG:-}" ]; then
  echo "ERROR: KUBECONFIG is empty — no cluster credentials available to this provisioner." >&2
  manual_cleanup_notice
  exit 0
fi

if [ ! -f "${KUBECONFIG}" ]; then
  echo "ERROR: KUBECONFIG points at a file that does not exist: ${KUBECONFIG}" >&2
  manual_cleanup_notice
  exit 0
fi

# Verify cluster connectivity, retrying a few times so a transient API-server blip
# does not disable the whole wait. kubectl's own error is echoed — the previous
# version discarded it, which made a one-line "skipping namespace wait" the only
# trace of a destroy that silently orphaned the agent namespace.
CONNECT_ATTEMPTS=3
connected=0
for i in $(seq 1 $CONNECT_ATTEMPTS); do
  if probe_err=$(kubectl get namespaces --request-timeout=30s -o name 2>&1 >/dev/null); then
    connected=1
    break
  fi
  echo "Cluster connectivity check $i/$CONNECT_ATTEMPTS failed: ${probe_err}" >&2
  if [ "$i" -lt "$CONNECT_ATTEMPTS" ]; then
    sleep 10
  fi
done

if [ "$connected" -ne 1 ]; then
  echo "ERROR: kubectl cannot reach the cluster with KUBECONFIG=${KUBECONFIG} after ${CONNECT_ATTEMPTS} attempts." >&2
  manual_cleanup_notice
  exit 0
fi

COUNTER=0
while [[ $COUNTER -lt $MAX_ATTEMPTS ]]; do
  COUNTER=$((COUNTER + 1))
  echo "Attempt $COUNTER/$MAX_ATTEMPTS: Checking for BRS-managed resources..."

  BRS_AGENT_NAMESPACES=$(kubectl get namespaces --no-headers 2>/dev/null | awk '{print $1}' | grep '^brs-backup-agent-' || true)
  # grep -c already prints 0 on no match (and exits non-zero); use `|| true` so
  # set -e doesn't abort. Using `|| echo "0"` here would append a second line,
  # producing "0\n0" and breaking the arithmetic below.
  BRS_AGENT_NS=$(echo "$BRS_AGENT_NAMESPACES" | grep -c . || true)

  VELERO_BACKUPS=0
  VELERO_RESTORES=0
  for ns in $BRS_AGENT_NAMESPACES; do
    NS_BACKUPS=$(kubectl get backups.velero.io -n "$ns" --no-headers 2>/dev/null | wc -l | xargs || echo "0")
    NS_RESTORES=$(kubectl get restores.velero.io -n "$ns" --no-headers 2>/dev/null | wc -l | xargs || echo "0")
    VELERO_BACKUPS=$((VELERO_BACKUPS + NS_BACKUPS))
    VELERO_RESTORES=$((VELERO_RESTORES + NS_RESTORES))
  done

  PROTECTED_NS=$(kubectl get namespaces -l cohesity.com/backup-enabled=true --no-headers 2>/dev/null | wc -l | xargs || echo "0")

  TOTAL=$((VELERO_BACKUPS + VELERO_RESTORES + PROTECTED_NS + BRS_AGENT_NS))

  if [ "$TOTAL" -eq 0 ]; then
    echo "All BRS-managed resources cleaned up."
    exit 0
  fi

  echo "  BRS-agent namespaces (brs-backup-agent-*): $BRS_AGENT_NS"
  echo "  Velero backups: $VELERO_BACKUPS"
  echo "  Velero restores: $VELERO_RESTORES"
  echo "  Protected namespaces: $PROTECTED_NS"

  if [[ $COUNTER -lt $MAX_ATTEMPTS ]]; then
    echo "Waiting ${SLEEP_DURATION}s before next check..."
    sleep $SLEEP_DURATION
  fi
done

echo "BRS-managed resources still present after $((MAX_ATTEMPTS * SLEEP_DURATION / 60)) minutes." >&2
echo "$BRS_AGENT_NAMESPACES" >&2
manual_cleanup_notice
exit 0
