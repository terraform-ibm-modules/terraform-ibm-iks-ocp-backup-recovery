#!/bin/bash
# Common utility functions for BRS scripts

# ---------------------------------------------------------------------------
# Verbose logging — all raw API responses are emitted to stderr when VERBOSE=1.
# Defined here so it is available to all scripts that source common_utils.sh.
# Individual scripts set VERBOSE="${VERBOSE:-0}" before sourcing this file,
# or rely on the VERBOSE env var set by the caller (e.g. VERBOSE=1 terraform apply).
# ---------------------------------------------------------------------------

# vlog LABEL JSON — print label + pretty-printed JSON to stderr when verbose.
# Safe to call even before VERBOSE is set (defaults to off).
vlog() {
  [[ "${VERBOSE:-0}" == "1" ]] || return 0
  local label="$1"
  local body="$2"
  echo "[VERBOSE] ${label}:" >&2
  echo "${body}" | jq '.' 2>/dev/null >&2 || echo "${body}" >&2
}

# Get IAM token from IBM Cloud.
# Usage: get_iam_token API_KEY ENDPOINT_TYPE
# Returns: IAM access token
#
# Reuses a caller-provided IAM_TOKEN environment variable when it holds a real
# token, otherwise exchanges the API key for a fresh token via curl (also used
# for token refresh during long-running polling and for destroy-time
# provisioners). To force a fresh token exchange (e.g. during refresh), callers
# must `unset IAM_TOKEN` before invoking this function.
get_iam_token() {
  local api_key=$1
  local endpoint_type=$2

  if [[ -n "${IAM_TOKEN:-}" && "${IAM_TOKEN}" != "null" ]]; then
    echo "${IAM_TOKEN}"
    return 0
  fi

  local iam_endpoint="${IBMCLOUD_IAM_API_ENDPOINT:-iam.cloud.ibm.com}"
  iam_endpoint=${iam_endpoint#https://}

  if [[ "$iam_endpoint" == "iam.cloud.ibm.com" && "$endpoint_type" == "private" ]]; then
    iam_endpoint="private.${iam_endpoint}"
  fi

  local response
  response=$(curl --retry 3 -s -X POST "https://${iam_endpoint}/identity/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --header 'Accept: application/json' \
    --data-urlencode 'grant_type=urn:ibm:params:oauth:grant-type:apikey' \
    --data-urlencode "apikey=${api_key}")  # pragma: allowlist secret

  vlog "POST IAM token exchange (${iam_endpoint})" "${response}"

  if echo "$response" | jq -e 'has("errorMessage")' > /dev/null; then
    echo "IAM Error: $(echo "$response" | jq -r '.errorMessage')" >&2
    exit 1
  fi

  # Validate the exchange actually produced a token.
  local token
  token=$(echo "$response" | jq -r '.access_token // empty')
  if [[ -z "$token" ]]; then
    echo "IAM Error: token exchange did not return an access_token." >&2
    echo "Response: $response" >&2
    exit 1
  fi

  echo "$token"
}
