#!/bin/bash
# trigger_backup_run.sh - Trigger an on-demand backup run, skipping if one is already active.
#
# BRS auto-starts a CloudArchiveDirect archival run as soon as a protection group is
# registered against a policy. If Terraform blindly fires another kRegular run on top
# of that, the API returns:
#   "CloudArchiveDirect job has an active archival task for primary target"
#
# This script checks for an existing active or recently-queued run first.
# If one is found it exits 0 without triggering a new run; the downstream
# wait_for_backup_run.sh poller will pick up whichever run completes first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common_utils.sh
source "${SCRIPT_DIR}/common_utils.sh"

if [ "$#" -lt 5 ]; then
  echo "Usage: $0 URL TENANT ENDPOINT_TYPE INSTANCE_ID PROTECTION_GROUP_ID" >&2
  echo "Note: IBMCLOUD_API_KEY must be set as an environment variable" >&2
  exit 1
fi

if [ -z "${IBMCLOUD_API_KEY:-}" ]; then # pragma: allowlist secret
  echo "ERROR: IBMCLOUD_API_KEY environment variable is not set" >&2
  exit 1
fi

URL=$1
TENANT=$2
ENDPOINT_TYPE=$3
# shellcheck disable=SC2034  # Accepted for signature parity with the other BRS scripts; not used here.
INSTANCE_ID=$4
PROTECTION_GROUP_ID=$5

# Extract numeric PG ID (after ::)
# Format: clusterid/::8009179080677672:1753125047518:126734 -> 8009179080677672:1753125047518:126734
API_PG_ID="${PROTECTION_GROUP_ID#*::}"

echo "=== trigger_backup_run.sh invoked at $(date) ===" >&2
echo "Protection Group ID (API): ${API_PG_ID}" >&2

IAM_TOKEN=$(get_iam_token "${IBMCLOUD_API_KEY}" "${ENDPOINT_TYPE}") # pragma: allowlist secret
export IAM_TOKEN

call_api() {
  local method=$1
  local path=$2
  shift 2

  local response
  response=$(curl --retry 3 -s -w "\n%{http_code}" -X "$method" "${URL}${path}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    -H "X-IBM-Tenant-Id: ${TENANT}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@")

  local http_code
  http_code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "API Error: HTTP $http_code from $method $path" >&2
    echo "Response: $body" >&2
    return 1
  fi

  echo "$body"
}

# Returns 0 if the status string is a non-terminal (active/queued) state.
is_active() {
  local status=$1
  case "$status" in
    Succeeded | Failed | Canceled | Skipped | Missed | SucceededWithWarning | \
    kSucceeded | kFailed | kCanceled | kSkipped | kMissed | kSucceededWithWarning)
      return 1 ;; # terminal — not active
    "")
      return 1 ;; # unknown / empty — treat as terminal
    *)
      return 0 ;; # anything else is active/queued
  esac
}

# Check whether the protection group already has an active (non-terminal) run
has_active_run() {
  local run_data
  run_data=$(call_api "GET" "/v2/data-protect/protection-groups/${API_PG_ID}/runs?numRuns=5&includeObjectDetails=false") || {
    echo "WARNING: Could not query runs; will proceed with trigger." >&2
    return 1
  }

  local total_runs
  total_runs=$(echo "$run_data" | jq '.runs | length')
  echo "Runs found: ${total_runs}" >&2

  for i in $(seq 0 $(( total_runs - 1 ))); do
    local run_status
    run_status=$(echo "$run_data" | jq -r ".runs[${i}].status // empty")
    echo "  Run[${i}] status: ${run_status:-<none>}" >&2

    if is_active "$run_status"; then
      echo "Active run detected (status=${run_status}). Skipping manual trigger." >&2
      return 0
    fi

    # Also check for active archival (copy) tasks on an otherwise-terminal run —
    # these are what actually produce the CloudArchiveDirect conflict.
    local num_archival
    num_archival=$(echo "$run_data" | jq ".runs[${i}].archivalInfo.archivalTargetResults | length // 0")
    for j in $(seq 0 $(( num_archival - 1 ))); do
      local archival_status
      archival_status=$(echo "$run_data" | jq -r ".runs[${i}].archivalInfo.archivalTargetResults[${j}].status // empty")
      echo "    Archival task[${j}] status: ${archival_status:-<none>}" >&2
      if is_active "$archival_status"; then
        echo "Active archival task detected (status=${archival_status}). Skipping manual trigger." >&2
        return 0
      fi
    done
  done

  return 1 # no active runs
}

main() {
  if has_active_run; then
    echo "BRS already has an active backup run in progress. No manual trigger needed." >&2
    echo "The downstream poller will wait for it to complete." >&2
    exit 0
  fi

  echo "No active run found. Triggering on-demand kRegular backup run..." >&2
  local payload='{"runType":"kRegular"}'
  local response
  response=$(call_api "POST" "/v2/data-protect/protection-groups/${API_PG_ID}/runs" \
    --data-raw "$payload") || {
    echo "WARNING: Trigger request failed; the scheduled run may be sufficient." >&2
    exit 0
  }

  echo "Backup run triggered successfully." >&2
  echo "$response" >&2
}

main
