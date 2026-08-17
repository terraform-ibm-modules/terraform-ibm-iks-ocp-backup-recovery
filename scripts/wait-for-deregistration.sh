#!/bin/bash
# wait-for-deregistration.sh
#
# Poll the BRS registrations list until this cluster's source registration is
# gone, confirming BRS has completed the async deregistration cleanup. Runs as a
# destroy-time provisioner between the source-registration DELETE and the
# deletion of the data source connection.
#
# Matched on connection ID / cluster endpoint rather than registration ID: a
# destroy-time provisioner can only read `self`, so passing the ID would mean
# referencing the registration resource, which inverts the destroy edge and runs
# this poller before the DELETE. The match tests the whole serialized
# registration object, so it does not depend on BRS's exact field paths.
#
# Usage:
#   $0 REGION TENANT BRS_ENDPOINT CONNECTION_ID CLUSTER_ENDPOINT [TIMEOUT_S] [POLL_S]
#
#   REGION           — IBM Cloud region (e.g. us-south)
#   TENANT           — X-IBM-Tenant-Id (e.g. watmhpj18k/)
#   BRS_ENDPOINT     — BRS hostname without scheme/path
#                      e.g. <guid>.<region>.backup-recovery.cloud.ibm.com
#   CONNECTION_ID    — data source connection ID this cluster registered against
#   CLUSTER_ENDPOINT — cluster API endpoint used at registration time
#   TIMEOUT_S        — total polling budget in seconds (default: 1800)
#   POLL_S           — sleep between polls in seconds   (default: 20)
#
# Required env var:
#   IBMCLOUD_API_KEY — IBM Cloud API key for the destination account (BRS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common_utils.sh
source "${SCRIPT_DIR}/common_utils.sh"

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 REGION TENANT BRS_ENDPOINT CONNECTION_ID CLUSTER_ENDPOINT [TIMEOUT_S] [POLL_S]" >&2
  exit 1
fi

REGION="${1:-}"
TENANT="${2:-}"
BRS_ENDPOINT="${3:-}"
CONNECTION_ID="${4:-}"
CLUSTER_ENDPOINT="${5:-}"
TIMEOUT_S="${6:-1800}"
POLL_S="${7:-20}"

# Grace period used only when the registration is never observed at all — see the
# "never seen" branch of the polling loop below.
GRACE_S=120

# Empty BRS endpoint or tenant means the resources were never created (e.g. a
# failure before registration); nothing to wait for.
if [ -z "${BRS_ENDPOINT}" ] || [ -z "${TENANT}" ]; then
  echo "wait-for-deregistration.sh: empty tenant/endpoint — skipping (resource may not have been created)." >&2
  exit 0
fi

if [ -z "${CONNECTION_ID}" ] && [ -z "${CLUSTER_ENDPOINT}" ]; then
  echo "wait-for-deregistration.sh: no connection ID and no cluster endpoint to match on — skipping." >&2
  exit 0
fi

if [ -z "${IBMCLOUD_API_KEY:-}" ]; then # pragma: allowlist secret
  echo "ERROR: IBMCLOUD_API_KEY environment variable is not set" >&2
  exit 1
fi

echo "=== wait-for-deregistration.sh invoked at $(date) ===" >&2
echo "region=${REGION}  tenant=${TENANT}" >&2
echo "matching on connection_id=${CONNECTION_ID}  cluster_endpoint=${CLUSTER_ENDPOINT}" >&2
echo "timeout=${TIMEOUT_S}s  poll=${POLL_S}s" >&2

# ---------------------------------------------------------------------------
# Login + set BRS service URL (same pattern as delete_auto_protect_pg.sh)
# ---------------------------------------------------------------------------
IBMCLOUD_API_ENDPOINT=$(get_ibmcloud_api_endpoint "${BRS_ENDPOINT}")
echo "Logging in to IBM Cloud (region: ${REGION}, endpoint: ${IBMCLOUD_API_ENDPOINT})..." >&2
ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -a "${IBMCLOUD_API_ENDPOINT}" -r "${REGION}" -q 2>&1 \
  | grep -v "^$" >&2 || true # pragma: allowlist secret

brs_url="https://${BRS_ENDPOINT}/v2"
echo "Setting BRS service URL: ${brs_url}" >&2
ibmcloud backup-recovery config set service-url "${brs_url}" 2>&1 \
  | grep -v "^$" >&2 || true

# Count the registrations whose serialized JSON mentions our connection ID or our
# cluster endpoint. Matching on the serialized object rather than a specific field
# keeps this working across BRS payload shapes (connectionId, connections[].connectionId,
# registrationInfo.endpoint, rootNode.name, ...).
count_matching() {
  echo "$1" | jq --arg conn "${CONNECTION_ID}" --arg ep "${CLUSTER_ENDPOINT}" '
    [ .registrations[]?
      | tojson as $reg
      | select(
          ($conn != "" and ($reg | contains($conn))) or
          ($ep   != "" and ($reg | contains($ep)))
        )
    ] | length
  ' 2>/dev/null || echo "-1"
}

# ---------------------------------------------------------------------------
# Polling loop — exit as soon as our registration disappears
# ---------------------------------------------------------------------------
elapsed=0
seen_once=0
warned_never_seen=0

while ((elapsed < TIMEOUT_S)); do

  raw=$(ibmcloud backup-recovery protection-source registrations-list \
    --xibm-tenant-id "${TENANT}" \
    --output json -q 2>&1) || {
    echo "[${elapsed}s] registrations-list failed — retrying in ${POLL_S}s" >&2
    sleep "${POLL_S}"
    ((elapsed += POLL_S)) || true
    continue
  }

  total=$(echo "${raw}" | jq '.registrations | length' 2>/dev/null || echo "-1")
  matching=$(count_matching "${raw}")

  if [[ "${total}" == "-1" || "${matching}" == "-1" ]]; then
    echo "[${elapsed}s] could not parse registrations-list response — retrying in ${POLL_S}s" >&2
    sleep "${POLL_S}"
    ((elapsed += POLL_S)) || true
    continue
  fi

  echo "[${elapsed}s] registrations for this cluster: ${matching} (tenant total: ${total})" >&2

  if ((matching > 0)); then
    seen_once=1
  else
    if ((seen_once == 1)) || ((total == 0)); then
      echo "=== wait-for-deregistration.sh: source deregistration confirmed (elapsed=${elapsed}s) ===" >&2
      exit 0
    fi

    # Never observed. Either BRS had already completed the deregistration before
    # the first poll, or neither identifier appears in this payload. Both are
    # indistinguishable from here, so hold for a short grace period rather than
    # returning instantly and letting the connection delete race the backend.
    if ((warned_never_seen == 0)); then
      warned_never_seen=1
      echo "[${elapsed}s] NOTE: no registration matched connection_id=${CONNECTION_ID} / endpoint=${CLUSTER_ENDPOINT}" >&2
      echo "[${elapsed}s] either it was already deregistered, or these identifiers are absent from the payload." >&2
      echo "[${elapsed}s] holding for a ${GRACE_S}s grace period before allowing the connection delete." >&2
    fi
    if ((elapsed >= GRACE_S)); then
      echo "=== wait-for-deregistration.sh: grace period elapsed, proceeding (elapsed=${elapsed}s) ===" >&2
      exit 0
    fi
  fi

  sleep "${POLL_S}"
  ((elapsed += POLL_S)) || true
done

echo "WARNING: timeout after ${TIMEOUT_S}s — a source registration for this cluster is still present." >&2
echo "The data source connection delete may fail with 'being used by the source'." >&2
# Exit 0 — non-fatal: Terraform destroy should proceed; a lingering registration
# record does not block resource deletion and will eventually be cleaned by BRS.
exit 0
