#!/usr/bin/env bash
##############################################################################
# Cleanup BRS Agent Runtime Resources
##############################################################################
# BRS agent creates namespaces and ClusterRoleBindings dynamically at runtime
# that Terraform doesn't manage. This script ensures they are properly deleted.
# It runs after source deregistration so the BRS agent is no longer actively
# managing these resources when they are removed.
#
# Usage:
#   cleanup_brs_agent_resources.sh <binaries_path>
#
# Environment variables:
#   KUBECONFIG - Path to kubeconfig file created by the terraform provider
#
# The script will:
# 1. Check if kubectl is available
# 2. Verify cluster connectivity via the stored kubeconfig
# 3. Delete all BRS-agent-created namespaces (pattern: brs-backup-agent-*)
# 4. Delete all BRS-agent-created ClusterRoleBindings (pattern: brs-backup-agent-*)
##############################################################################

set -e

# The binaries downloaded by the install-binaries script are located in the /tmp directory.
export PATH=$PATH:${1:-"/tmp"}

echo "Cleaning up BRS-agent-created namespaces and cluster role bindings..."

# Check if kubectl is available
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found; skipping BRS-agent cleanup."
  exit 0
fi

# Verify cluster connectivity using the kubeconfig created by the terraform provider.
if ! kubectl version --request-timeout=15s >/dev/null 2>&1; then
  echo "kubectl cannot reach cluster with stored kubeconfig; skipping BRS-agent cleanup."
  exit 0
fi

# Delete namespaces by runtime-generated naming pattern
echo "Deleting BRS-agent namespaces..."
kubectl get namespace --no-headers | awk '{print $1}' | grep -E '^brs-backup-agent-' | while read -r ns; do
  if [ -n "$ns" ]; then
    echo "  Deleting namespace: $ns"
    kubectl delete namespace "$ns" --ignore-not-found=true || true
  fi
done

# Delete ClusterRoleBindings by runtime-generated naming pattern
echo "Deleting BRS-agent ClusterRoleBindings..."
kubectl get clusterrolebinding --no-headers | awk '{print $1}' | grep -E '^brs-backup-agent-' | while read -r crb; do
  if [ -n "$crb" ]; then
    echo "  Deleting ClusterRoleBinding: $crb"
    kubectl delete clusterrolebinding "$crb" --ignore-not-found=true || true
  fi
done

echo "Cleanup complete."
