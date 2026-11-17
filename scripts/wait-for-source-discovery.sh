#!/bin/bash
# wait-for-source-discovery.sh
#
# Poll the BRS registration-get API until the initial source refresh has
# completed — i.e., until lastRefreshedTimeMsecs is substantially greater
# than registrationTimeMsecs (indicating Velero has completed at least one
# full namespace discovery pass and sent the results to BRS).
#
# Uses ibmcloud backup-recovery CLI — same pattern as delete_auto_protect_pg.sh.
#
# Usage:
#   $0 REGION TENANT REGISTRATION_ID BRS_ENDPOINT [TIMEOUT_S] [POLL_S]
#
#   REGION           — IBM Cloud region (e.g. us-south)
#   TENANT           — X-IBM-Tenant-Id (e.g. watmhpj18k/)
#   REGISTRATION_ID  — numeric source_id from ibm_backup_recovery_source_registration
#   BRS_ENDPOINT     — BRS hostname without scheme/path
#                      e.g. <guid>.<region>.backup-recovery.cloud.ibm.com
#   TIMEOUT_S        — total polling budget in seconds (default: 1800)
#   POLL_S           — sleep between polls in seconds   (default: 30)
#
# Required env var:
#   IBMCLOUD_API_KEY — IBM Cloud API key for the destination account (BRS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common_utils.sh
source "${SCRIPT_DIR}/common_utils.sh"

if [ "$#" -lt 4 ]; then
  echo "Usage: $0 REGION TENANT REGISTRATION_ID BRS_ENDPOINT [TIMEOUT_S] [POLL_S]" >&2
  exit 1
fi

if [ -z "${IBMCLOUD_API_KEY:-}" ]; then # pragma: allowlist secret
  echo "ERROR: IBMCLOUD_API_KEY environment variable is not set" >&2
  exit 1
fi

REGION=$1
TENANT=$2
REGISTRATION_ID=$3
BRS_ENDPOINT=$4
# Sanitise to a bare hostname (any "https://" scheme and "/v2" path removed) so
# the service URL below always carries the scheme and "/v2" exactly once.
BRS_ENDPOINT=$(brs_endpoint_host "${BRS_ENDPOINT}")
TIMEOUT_S="${5:-1800}"
POLL_S="${6:-30}"

CHILDREN_TIMEOUT_S="${TIMEOUT_S}"
CHILDREN_POLL_S="${POLL_S}"

echo "=== wait-for-source-discovery.sh invoked at $(date) ===" >&2
echo "region=${REGION}  tenant=${TENANT}  registration_id=${REGISTRATION_ID}" >&2
echo "timeout=${TIMEOUT_S}s  poll=${POLL_S}s" >&2

# ---------------------------------------------------------------------------
# Login + set BRS service URL (same pattern as delete_auto_protect_pg.sh)
# ---------------------------------------------------------------------------
IBMCLOUD_API_ENDPOINT=$(get_ibmcloud_api_endpoint "${BRS_ENDPOINT}")
echo "Logging in to IBM Cloud (region: ${REGION}, endpoint: ${IBMCLOUD_API_ENDPOINT})..." >&2
ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -a "${IBMCLOUD_API_ENDPOINT}" -r "${REGION}" -q 2>&1 \
  | grep -v "^$" >&2 || true  # pragma: allowlist secret

brs_url="$(brs_endpoint_service_url "${BRS_ENDPOINT}")"
echo "Setting BRS service URL: ${brs_url}" >&2
ibmcloud backup-recovery config set service-url "${brs_url}" 2>&1 \
  | grep -v "^$" >&2 || true

# ---------------------------------------------------------------------------
# Polling loop: Phase 1 waits for the source registration to reach "Finished"
# ---------------------------------------------------------------------------
elapsed=0
while (( elapsed < TIMEOUT_S )); do

  raw=$(ibmcloud backup-recovery protection-source registration-get \
    --id "${REGISTRATION_ID}" \
    --xibm-tenant-id "${TENANT}" \
    --output json -q 2>&1) || {
      echo "[${elapsed}s] registration-get failed — retrying in ${POLL_S}s" >&2
      sleep "${POLL_S}"
      (( elapsed += POLL_S )) || true
      continue
    }

  auth=$(echo "${raw}" | jq -r '.authenticationStatus // ""')
  echo "[${elapsed}s] authStatus=${auth}" >&2

  if [[ "${auth}" == "Finished" ]]; then
    echo "=== wait-for-source-discovery.sh: registration complete (authStatus=${auth}, elapsed=${elapsed}s) ===" >&2
    break
  fi

  if [[ "${auth}" =~ ^(Failed|Error)$ ]]; then
    echo "ERROR: source ${REGISTRATION_ID} registration failed (authStatus=${auth})" >&2
    exit 1
  fi

  echo "[${elapsed}s] authStatus not Finished yet (${auth}) — waiting…" >&2

  sleep "${POLL_S}"
  (( elapsed += POLL_S )) || true
done

if (( elapsed >= TIMEOUT_S )); then
  echo "ERROR: timeout after ${TIMEOUT_S}s — source ${REGISTRATION_ID} initial refresh did not complete." >&2
  echo "Check that the Data Source Connector pod is Running in the ibm-brs-data-source-connector namespace." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Phase 2: wait for at least one child node to appear in protection-sources
# so the data source read in Terraform can resolve object names to IDs.
#
# The current API response returns populated child nodes directly under
# .protectionSources[].nodes[] without the older
# .protectionSource.kubernetesProtectionSource.type field. Treat any child node
# as proof that the source tree has been indexed.
# ---------------------------------------------------------------------------
echo "=== Phase 2: waiting for source child nodes to be indexed ===" >&2
elapsed2=0
while (( elapsed2 < CHILDREN_TIMEOUT_S )); do

  src_raw=$(ibmcloud backup-recovery protection-source list \
    --xibm-tenant-id "${TENANT}" \
    --environments "kKubernetes" \
    --id "${REGISTRATION_ID}" \
    --output json -q 2>&1) || {
      echo "[${elapsed2}s] protection-source list failed — retrying in ${CHILDREN_POLL_S}s" >&2
      sleep "${CHILDREN_POLL_S}"
      (( elapsed2 += CHILDREN_POLL_S )) || true
      continue
    }

  # When --id is used the API returns the source's indexed child nodes at
  # .protectionSources[].nodes[]. Count any child node because current payloads
  # do not include the older kubernetesProtectionSource.type field.
  child_count=$(echo "${src_raw}" | jq '
    [ .protectionSources[]?
      | .nodes[]?
    ] | length
  ' 2>/dev/null || echo "0")

  echo "[${elapsed2}s] child nodes under source ${REGISTRATION_ID}: ${child_count}" >&2

  if (( child_count > 0 )); then
    echo "=== wait-for-source-discovery.sh: ${child_count} child node(s) indexed (elapsed2=${elapsed2}s) ===" >&2
    exit 0
  fi

  sleep "${CHILDREN_POLL_S}"
  (( elapsed2 += CHILDREN_POLL_S )) || true
done

echo "WARNING: timeout after ${CHILDREN_TIMEOUT_S}s — no child nodes indexed for source ${REGISTRATION_ID}." >&2
echo "Terraform protection_groups using object names may fail with 'objects.0.id required'." >&2
# Exit 0 — non-fatal: Terraform still proceeds; will fail at protection_group if name can't be resolved.
exit 0
