#!/bin/bash
set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common_utils.sh
source "${SCRIPT_DIR}/common_utils.sh"

if [ "$#" -lt 5 ]; then
  echo "Usage: $0 URL TENANT ENDPOINT_TYPE INSTANCE_ID RECOVERY_ID [TIMEOUT_MINUTES] [POLL_INTERVAL_SECONDS] [BINARIES_PATH]" >&2
  echo "Note: IBMCLOUD_API_KEY must be set as an environment variable" >&2
  exit 1
fi

if [ -z "${IBMCLOUD_API_KEY:-}" ]; then  # pragma: allowlist secret
  echo "ERROR: IBMCLOUD_API_KEY environment variable is not set" >&2
  exit 1
fi

URL=$1
TENANT=$2
ENDPOINT_TYPE=$3
# shellcheck disable=SC2034  # Used in error messages and file paths
INSTANCE_ID=$4
RECOVERY_ID=$5
TIMEOUT_MINUTES=${6:-30}
POLL_INTERVAL_SECONDS=${7:-30}
BINARIES_PATH=${8:-/tmp}

export PATH="${PATH}:${BINARIES_PATH}"

echo "=== Waiting for Recovery Completion ===" >&2
echo "Recovery ID: ${RECOVERY_ID}" >&2
echo "Timeout: ${TIMEOUT_MINUTES} minutes" >&2
echo "Poll Interval: ${POLL_INTERVAL_SECONDS} seconds" >&2

IAM_TOKEN=$(get_iam_token "${IBMCLOUD_API_KEY}" "${ENDPOINT_TYPE}")

TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT_SECONDS ]; do
  echo "Checking recovery status (elapsed: ${ELAPSED}s)..." >&2

  # Get recovery status
  response=$(curl --retry 3 -s -w "\n%{http_code}" -X GET "${URL}/v2/data-protect/recoveries/${RECOVERY_ID}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    -H "X-IBM-Tenant-Id: ${TENANT}" \
    -H "Accept: application/json")

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "Recovery Status API Error: HTTP $http_code" >&2
    echo "Response: $body" >&2
    exit 1
  fi

  # Extract status from response
  status=$(echo "$body" | jq -r '.status // empty')

  if [ -z "$status" ]; then
    echo "ERROR: Could not extract status from response" >&2
    echo "Response: $body" >&2
    exit 1
  fi

  echo "Recovery status: $status" >&2

  # Check if recovery is complete
  # Possible statuses: Running, Succeeded, Failed, Canceled, etc.
  case "$status" in
    "Succeeded"|"Success")
      echo "✓ Recovery completed successfully!" >&2
      echo "$body" | jq '.'
      exit 0
      ;;
    "Failed"|"Failure")
      echo "ERROR: Recovery failed!" >&2
      echo "$body" | jq '.'
      exit 1
      ;;
    "Canceled"|"Cancelled")
      echo "ERROR: Recovery was canceled!" >&2
      echo "$body" | jq '.'
      exit 1
      ;;
    "Running"|"InProgress"|"Accepted")
      echo "Recovery still in progress..." >&2
      ;;
    *)
      echo "Unknown recovery status: $status" >&2
      ;;
  esac

  sleep "$POLL_INTERVAL_SECONDS"
  ELAPSED=$((ELAPSED + POLL_INTERVAL_SECONDS))
done

echo "ERROR: Recovery did not complete within ${TIMEOUT_MINUTES} minutes" >&2
exit 1

# Made with Bob
