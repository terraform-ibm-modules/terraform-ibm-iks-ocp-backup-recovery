#!/bin/bash
# trigger_recovery.sh — POST a new recovery to the BRS API and print the recovery_id.
#
# Supports both same-cluster and cross-cluster recovery. For cross-cluster, pass
# a non-empty TARGET_SOURCE_ID; for same-cluster, pass an empty string or omit it.
#
# Usage:
#   trigger_recovery.sh URL TENANT ENDPOINT_TYPE INSTANCE_ID \
#       PG_ID SNAPSHOT_ID RECOVERY_NAME NAMESPACE_PREFIX \
#       [TARGET_SOURCE_ID] [BINARIES_PATH]
#
# IBMCLOUD_API_KEY must be set as an environment variable.
#
# The recovery_id is written to stdout so callers can capture it:
#   recovery_id=$(trigger_recovery.sh ...)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common_utils.sh
source "${SCRIPT_DIR}/common_utils.sh"

if [ "$#" -lt 8 ]; then
  echo "Usage: $0 URL TENANT ENDPOINT_TYPE INSTANCE_ID PG_ID SNAPSHOT_ID RECOVERY_NAME NAMESPACE_PREFIX [TARGET_SOURCE_ID] [BINARIES_PATH]" >&2
  echo "Note: IBMCLOUD_API_KEY must be set as an environment variable" >&2 # pragma: allowlist secret
  exit 1
fi

if [ -z "${IBMCLOUD_API_KEY:-}" ]; then # pragma: allowlist secret
  echo "ERROR: IBMCLOUD_API_KEY environment variable is not set" >&2
  exit 1
fi

URL=$1
TENANT=$2
ENDPOINT_TYPE=$3
INSTANCE_ID=$4
PG_ID=$5
SNAPSHOT_ID=$6
RECOVERY_NAME=$7
NAMESPACE_PREFIX=$8
TARGET_SOURCE_ID=${9:-}
BINARIES_PATH=${10:-/tmp}

export PATH="${PATH}:${BINARIES_PATH}"
VERBOSE="${VERBOSE:-1}"

echo "=== trigger_recovery.sh ===" >&2
echo "PG ID:           ${PG_ID}" >&2
echo "Snapshot ID:     ${SNAPSHOT_ID}" >&2
echo "Recovery name:   ${RECOVERY_NAME}" >&2
echo "Namespace prefix: ${NAMESPACE_PREFIX}" >&2
if [ -n "${TARGET_SOURCE_ID}" ]; then
  echo "Target source ID: ${TARGET_SOURCE_ID} (cross-cluster)" >&2
else
  echo "Recovery type:   same-cluster" >&2
fi

IAM_TOKEN=$(get_iam_token "${IBMCLOUD_API_KEY}" "${ENDPOINT_TYPE}") # pragma: allowlist secret

# Build the recovery payload. The structure is identical for same-cluster and
# cross-cluster except for recoveryTargetConfig.
if [ -n "${TARGET_SOURCE_ID}" ]; then
  # Cross-cluster: recover to a new source (TARGET_SOURCE_ID)
  RECOVERY_TARGET_CONFIG=$(cat <<EOF
{
  "recoverToNewSource": true,
  "newSourceConfig": {
    "source": { "id": ${TARGET_SOURCE_ID} }
  }
}
EOF
)
else
  # Same-cluster: recover to original source
  RECOVERY_TARGET_CONFIG='{"recoverToNewSource": false}'
fi

RECOVERY_PAYLOAD=$(cat <<PAYLOAD
{
  "name": "${RECOVERY_NAME}",
  "snapshotEnvironment": "kKubernetes",
  "kubernetesParams": {
    "recoveryAction": "RecoverNamespaces",
    "objects": [{"snapshotId": "${SNAPSHOT_ID}", "protectionGroupId": "${PG_ID}"}],
    "recoverNamespaceParams": {
      "targetEnvironment": "kKubernetes",
      "kubernetesTargetParams": {
        "objects": [{"snapshotId": "${SNAPSHOT_ID}", "protectionGroupId": "${PG_ID}"}],
        "recoveryTargetConfig": ${RECOVERY_TARGET_CONFIG},
        "renameRecoveredNamespacesParams": {"prefix": "${NAMESPACE_PREFIX}"}
      }
    }
  }
}
PAYLOAD
)

echo "Triggering recovery..." >&2
vlog "POST /v2/data-protect/recoveries payload" "${RECOVERY_PAYLOAD}"

response=$(curl --retry 3 -s -w "\n%{http_code}" -X POST "${URL}/v2/data-protect/recoveries" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "X-IBM-Tenant-Id: ${TENANT}" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d "${RECOVERY_PAYLOAD}")

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

vlog "POST /v2/data-protect/recoveries → HTTP ${http_code}" "${body}"

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "ERROR: Recovery API returned HTTP ${http_code}" >&2
  echo "${body}" >&2
  exit 1
fi

recovery_id=$(echo "$body" | jq -r '.id // empty')
if [ -z "$recovery_id" ]; then
  echo "ERROR: Could not extract recovery_id from response" >&2
  echo "${body}" >&2
  exit 1
fi

echo "Recovery ID: ${recovery_id}" >&2
echo "✓ Recovery triggered successfully!" >&2

# Write recovery_id to a file keyed by INSTANCE_ID for reference
echo "$recovery_id" > "/tmp/recovery_id_${INSTANCE_ID}.txt"

# Print recovery_id to stdout — callers capture this
echo "$recovery_id"
