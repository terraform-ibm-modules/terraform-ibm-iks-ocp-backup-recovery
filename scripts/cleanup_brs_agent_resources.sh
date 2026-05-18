#!/usr/bin/env bash
##############################################################################
# Cleanup BRS Agent Runtime Resources (Schematics-Compatible)
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
#   KUBECONFIG       - Path to kubeconfig file (stored at apply time)
#   CLUSTER_ID       - IBM Cloud cluster ID (used for IBM Cloud CLI fallback)
#   IC_API_KEY       - IBM Cloud API key (optional; enables ibmcloud CLI fallback)
#   IBMCLOUD_API_KEY - IBM Cloud API key alternative name (optional)
#
# The script will:
# 1. Check if kubectl is available
# 2. Verify cluster connectivity; if it fails and IC_API_KEY/IBMCLOUD_API_KEY
#    is set, attempt to get a fresh kubeconfig via IBM Cloud CLI (public endpoint)
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

# Check cluster connectivity; if it fails, try IBM Cloud CLI fallback.
# This handles cases where the stored kubeconfig uses a private endpoint that
# is not reachable from the current execution environment (e.g., CI runners).
if ! kubectl version --request-timeout=15s >/dev/null 2>&1; then
  echo "kubectl cannot reach cluster with stored kubeconfig; attempting IBM Cloud CLI fallback..."

  IBMCLOUD_APIKEY="${IC_API_KEY:-${IBMCLOUD_API_KEY:-}}"

  if [ -n "${IBMCLOUD_APIKEY}" ] && [ -n "${CLUSTER_ID:-}" ] && command -v ibmcloud >/dev/null 2>&1; then
    echo "Logging into IBM Cloud..."
    if ibmcloud login -a https://cloud.ibm.com --apikey "${IBMCLOUD_APIKEY}" --quiet 2>&1; then
      echo "Getting fresh kubeconfig for cluster ${CLUSTER_ID} (public endpoint)..."
      # ibmcloud ks cluster config uses the cluster's default (public) endpoint,
      # bypassing the private endpoint stored in the original kubeconfig.
      ibmcloud ks cluster config --cluster "${CLUSTER_ID}" --admin 2>&1 || true

      if kubectl version --request-timeout=15s >/dev/null 2>&1; then
        echo "Successfully connected to cluster via IBM Cloud CLI."
      else
        echo "Still cannot reach cluster after IBM Cloud CLI login; skipping BRS-agent cleanup."
        exit 0
      fi
    else
      echo "IBM Cloud login failed; skipping BRS-agent cleanup."
      exit 0
    fi
  else
    echo "kubectl cannot reach the target cluster; skipping BRS-agent cleanup."
    exit 0
  fi
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
