#!/bin/bash
set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common_utils.sh
source "${SCRIPT_DIR}/common_utils.sh"

if [ "$#" -lt 4 ]; then
  echo "Usage: $0 URL TENANT ENDPOINT_TYPE PROTECTION_GROUP_ID" >&2
  echo "Note: API_KEY must be set as an environment variable" >&2
  exit 1
fi

URL=$1
TENANT=$2
ENDPOINT_TYPE=$3
PROTECTION_GROUP_ID=$4

# Extract numeric PG ID (after ::)
# Format: clusterid/::timestamp:id:id -> timestamp:id:id
API_PG_ID="${PROTECTION_GROUP_ID#*::}"

IAM_TOKEN="" # pragma: allowlist secret

call_api() {
  local method=$1
  local path=$2
  shift 2
  local response http_code body

  response=$(curl --retry 3 -s -w "\n%{http_code}" -X "$method" "${URL}${path}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    -H "X-IBM-Tenant-Id: ${TENANT}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@")

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "API warning: HTTP $http_code from $method $path" >&2
    echo "$body" >&2
    return 1
  fi
  echo "$body"
}

is_running() {
  local status=$1
  case "$status" in
    Running | Accepted | Queued | kRunning | kAccepted | kQueued) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  echo "Getting IAM token..."
  IAM_TOKEN=$(get_iam_token "${API_KEY}" "${ENDPOINT_TYPE}") # pragma: allowlist secret

  echo "Pausing protection group ${API_PG_ID} to block new runs..."
  call_api "POST" "/v2/data-protect/protection-groups/${API_PG_ID}/states" \
    --data-raw '{"action":"kPause"}' > /dev/null \
    || echo "Pause request failed or not supported; continuing anyway..."

  echo "Waiting 30s for any in-flight run state to surface..."
  sleep 30

  echo "Checking for active backup runs on protection group: ${API_PG_ID}"
  local run_data
  run_data=$(call_api "GET" "/v2/data-protect/protection-groups/${API_PG_ID}/runs?includeObjectDetails=false" || echo '{"runs":[]}')

  local run_id run_status task_id
  run_id=$(echo "$run_data" | jq -r '.runs[0].id // empty')
  run_status=$(echo "$run_data" | jq -r '.runs[0].status // empty')
  task_id=$(echo "$run_data" | jq -r '.runs[0].archivalInfo.archivalTargetResults[0].archivalTaskId // empty')

  echo "Latest run: id=${run_id:-<none>}, status=${run_status:-<none>}"

  if [[ -z "$run_id" ]]; then
    echo "No runs found. Protection group is ready for deletion."
    exit 0
  fi

  if ! is_running "$run_status"; then
    echo "Latest run status is '${run_status}'. No cancellation needed."
    exit 0
  fi

  echo "Active backup run detected (status: ${run_status}). Canceling run ${run_id}..."

  local cancel_payload
  if [[ -n "$task_id" ]]; then
    cancel_payload="{\"action\": \"Cancel\", \"cancelParams\": [{\"runId\": \"${run_id}\", \"localTaskId\": \"${task_id}\"}]}"
  else
    cancel_payload="{\"action\": \"Cancel\", \"cancelParams\": [{\"runId\": \"${run_id}\"}]}"
  fi

  call_api "POST" "/v2/data-protect/protection-groups/${API_PG_ID}/runs/actions" \
    --data-raw "$cancel_payload" > /dev/null || echo "Cancel request may have failed, continuing..."

  echo "Waiting for run to stop..."
  local timeout_at
  timeout_at=$(( $(date +%s) + 600 ))

  while [[ "$(date +%s)" -lt "$timeout_at" ]]; do
    sleep 15
    run_data=$(call_api "GET" "/v2/data-protect/protection-groups/${API_PG_ID}/runs?includeObjectDetails=false" || echo '{"runs":[]}')
    run_status=$(echo "$run_data" | jq -r '.runs[0].status // empty')
    echo "Current run status: ${run_status:-<unknown>}"

    if ! is_running "${run_status:-unknown}"; then
      echo "Run ${run_id} stopped (status: ${run_status}). Ready for deletion."
      exit 0
    fi
  done

  echo "WARNING: Timed out (10 min) waiting for run cancellation. Proceeding anyway." >&2
  exit 0
}

main
