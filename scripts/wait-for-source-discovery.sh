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
TIMEOUT_S="${5:-1800}"
POLL_S="${6:-30}"

# Minimum refresh lag (ms) to consider initial discovery complete.
# The registration sets lastRefreshedTimeMsecs only a few seconds after
# registrationTimeMsecs on first contact.  A full Velero discovery pass
# typically takes 1–5 minutes; we require at least 60 s of lag to avoid
# treating that initial superficial refresh as "done".
MIN_REFRESH_LAG_MS=60000

# After the registration-get check passes we additionally poll
# protection-sources until at least one child node (namespace) is present
# under the registered cluster source.  This confirms the BRS API has fully
# indexed the source tree so protection_group objects can be resolved by name.
# Without this extra check the data source read immediately after apply may
# return an empty nodes list, causing "objects.0.id required" errors.
CHILDREN_TIMEOUT_S="${TIMEOUT_S}"
CHILDREN_POLL_S="${POLL_S}"

echo "=== wait-for-source-discovery.sh invoked at $(date) ===" >&2
echo "region=${REGION}  tenant=${TENANT}  registration_id=${REGISTRATION_ID}" >&2
echo "timeout=${TIMEOUT_S}s  poll=${POLL_S}s" >&2

# ---------------------------------------------------------------------------
# Login + set BRS service URL (same pattern as delete_auto_protect_pg.sh)
# ---------------------------------------------------------------------------
echo "Logging in to IBM Cloud (region: ${REGION})..." >&2
ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r "${REGION}" -q 2>&1 \
  | grep -v "^$" >&2 || true  # pragma: allowlist secret

brs_url="https://${BRS_ENDPOINT}/v2"
echo "Setting BRS service URL: ${brs_url}" >&2
ibmcloud backup-recovery config set service-url "${brs_url}" 2>&1 \
  | grep -v "^$" >&2 || true

# ---------------------------------------------------------------------------
# Polling loop
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

  # The CLI returns timestamps as floating-point (e.g. 1.786125694124e+12).
  # Use jq to convert both to integers before comparing so bash arithmetic
  # doesn't choke on scientific notation.
  auth=$(echo "${raw}" | jq -r '.authenticationStatus // ""')
  lag=$(echo "${raw}" | jq '
    (.lastRefreshedTimeMsecs // 0 | floor) -
    (.registrationTimeMsecs  // 0 | floor)
  ')

  echo "[${elapsed}s] authStatus=${auth}  lag=${lag}ms" >&2

  if [[ "${auth}" == "Finished" ]] && (( lag >= MIN_REFRESH_LAG_MS )); then
    echo "=== wait-for-source-discovery.sh: registration refresh complete (lag=${lag}ms, elapsed=${elapsed}s) ===" >&2
    break
  fi

  if (( lag < MIN_REFRESH_LAG_MS )); then
    echo "[${elapsed}s] refresh lag ${lag}ms < ${MIN_REFRESH_LAG_MS}ms — waiting for initial Velero discovery pass…" >&2
  else
    echo "[${elapsed}s] authStatus not Finished yet (${auth}) — waiting…" >&2
  fi

  sleep "${POLL_S}"
  (( elapsed += POLL_S )) || true
done

if (( elapsed >= TIMEOUT_S )); then
  echo "ERROR: timeout after ${TIMEOUT_S}s — source ${REGISTRATION_ID} initial refresh did not complete." >&2
  echo "Check that the Data Source Connector pod is Running in the ibm-brs-data-source-connector namespace." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Phase 2: wait for at least one namespace to appear in protection-sources
# so the data source read in Terraform can resolve object names to IDs.
#
# When --id REGISTRATION_ID is passed the CLI returns the cluster's children
# directly at .protectionSources[].nodes[] (the cluster node itself is not
# repeated in the response).  Namespaces have type "kNamespace".  We count
# those directly rather than trying to find the cluster node and descend.
# ---------------------------------------------------------------------------
echo "=== Phase 2: waiting for source children (namespaces) to be indexed ===" >&2
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

  # When --id is used the API returns the cluster's children at
  # .protectionSources[].nodes[].  Count entries whose type is kNamespace.
  child_count=$(echo "${src_raw}" | jq '
    [ .protectionSources[]?
      | .nodes[]?
      | select(.protectionSource.kubernetesProtectionSource.type == "kNamespace")
    ] | length
  ' 2>/dev/null || echo "0")

  echo "[${elapsed2}s] namespace children under source ${REGISTRATION_ID}: ${child_count}" >&2

  if (( child_count > 0 )); then
    echo "=== wait-for-source-discovery.sh: ${child_count} namespace(s) indexed (elapsed2=${elapsed2}s) ===" >&2
    exit 0
  fi

  sleep "${CHILDREN_POLL_S}"
  (( elapsed2 += CHILDREN_POLL_S )) || true
done

echo "WARNING: timeout after ${CHILDREN_TIMEOUT_S}s — no namespace children indexed for source ${REGISTRATION_ID}." >&2
echo "Terraform protection_groups using object names may fail with 'objects.0.id required'." >&2
# Exit 0 — non-fatal: Terraform still proceeds; will fail at protection_group if name can't be resolved.
exit 0
