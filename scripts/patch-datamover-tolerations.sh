#!/bin/bash
# patch-datamover-tolerations.sh
#
# Configurable stopgap for tainted worker nodes:
# Patches the cohesity-dm DaemonSet with user-specified tolerations once
# BRS has registered the source cluster and deployed the agent.
#
# Environment variables:
#   KUBECONFIG       — path to kubeconfig file (optional)
#   CLUSTER_ENDPOINT — cluster API server endpoint (optional, e.g. https://...)
#   CLUSTER_TOKEN    — bearer token for Kubernetes API (optional)
#   TOLERATIONS_JSON — JSON array of toleration objects
#   BINARIES_PATH    — directory where kubectl/jq are installed (default: /tmp)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common_utils.sh
source "${SCRIPT_DIR}/common_utils.sh"

BINARIES_PATH="${BINARIES_PATH:-/tmp}"
export PATH="${BINARIES_PATH}:${PATH}"

TOLERATIONS_JSON="${TOLERATIONS_JSON:-[]}"
if [ "${TOLERATIONS_JSON}" = "[]" ] || [ -z "${TOLERATIONS_JSON}" ]; then
  echo "No datamover tolerations specified; skipping patch."
  exit 0
fi

run_kubectl() {
  if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
    kubectl "$@"
  elif [ -n "${CLUSTER_ENDPOINT:-}" ] && [ -n "${CLUSTER_TOKEN:-}" ]; then
    kubectl --server="${CLUSTER_ENDPOINT}" --token="${CLUSTER_TOKEN}" --insecure-skip-tls-verify=true "$@"
  else
    kubectl "$@"
  fi
}

echo "=== Searching for cohesity-dm DaemonSet... ==="
AGENT_NS=""
for _ in $(seq 1 30); do
  AGENT_NS=$(run_kubectl get ds -A -l name=cohesity-dm -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
  if [ -n "${AGENT_NS}" ]; then
    break
  fi
  sleep 2
done

if [ -z "${AGENT_NS}" ]; then
  echo "WARNING: cohesity-dm DaemonSet not found in cluster after 60s; skipping tolerations patch." >&2
  exit 0
fi

echo "Found cohesity-dm in namespace: ${AGENT_NS}"

PATCH_PAYLOAD=$(jq -n --argjson tols "${TOLERATIONS_JSON}" '{"spec":{"template":{"spec":{"tolerations": $tols}}}}')

echo "Applying tolerations patch to cohesity-dm DaemonSet..."
if run_kubectl patch ds cohesity-dm -n "${AGENT_NS}" --type='strategic' -p "${PATCH_PAYLOAD}"; then
  echo "=== Successfully patched cohesity-dm DaemonSet with tolerations ==="
  exit 0
fi

# Fallback: direct HTTP PATCH to Kubernetes API server if kubectl failed
if [ -n "${CLUSTER_ENDPOINT:-}" ] && [ -n "${CLUSTER_TOKEN:-}" ]; then
  echo "kubectl patch failed; attempting direct Kubernetes API PATCH..."
  HTTP_CODE=$(curl -sSk -o /dev/null -w "%{http_code}" -X PATCH \
    -H "Authorization: Bearer ${CLUSTER_TOKEN}" \
    -H "Content-Type: application/strategic-merge-patch+json" \
    "${CLUSTER_ENDPOINT}/apis/apps/v1/namespaces/${AGENT_NS}/daemonsets/cohesity-dm" \
    -d "${PATCH_PAYLOAD}")
  if [[ "${HTTP_CODE}" =~ ^2 ]]; then
    echo "=== Successfully patched cohesity-dm DaemonSet via Kubernetes REST API ==="
    exit 0
  fi
  echo "ERROR: Kubernetes REST API PATCH returned HTTP ${HTTP_CODE}" >&2
  exit 1
fi

echo "ERROR: Failed to patch cohesity-dm DaemonSet" >&2
exit 1
