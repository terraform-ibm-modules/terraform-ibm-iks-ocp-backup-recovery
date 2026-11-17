#!/bin/bash
# Common utility functions for BRS scripts

# ---------------------------------------------------------------------------
# BRS endpoint sanitising.
#
# The BRS instance endpoints (extensions.endpoints.public / .private) are bare
# hostnames, e.g. <guid>.us-east.backup-recovery.cloud.ibm.com. Callers may
# nonetheless pass a value that already carries "https://" and/or a "/v2" suffix,
# which would otherwise yield "https://https://host/v2/v2" style URLs.
# These helpers accept any of those forms and always return the same result.
# ---------------------------------------------------------------------------

# brs_endpoint_host ENDPOINT — print the bare hostname.
# Strips any http(s):// scheme, then everything from the first "/" (path such as
# "/v2" and any trailing slashes), plus surrounding whitespace.
#   host                         -> host
#   https://host                 -> host
#   https://host/v2              -> host
#   https://host/v2/             -> host
#   https://https://host/v2      -> host
brs_endpoint_host() {
  local e="${1:-}"
  e="${e#"${e%%[![:space:]]*}"}"   # trim leading whitespace
  e="${e%"${e##*[![:space:]]}"}"   # trim trailing whitespace
  # Loop: tolerate a scheme that was already doubled ("https://https://host").
  while [[ "${e}" == http://* || "${e}" == https://* ]]; do
    e="${e#http://}"
    e="${e#https://}"
  done
  e="${e%%/*}"
  echo "${e}"
}

# brs_endpoint_url ENDPOINT — print "https://<host>" (scheme once, no path).
# Use for scripts that append their own "/v2/..." path.
brs_endpoint_url() {
  local host
  host=$(brs_endpoint_host "${1:-}")
  [[ -n "${host}" ]] || return 0
  echo "https://${host}"
}

# brs_endpoint_service_url ENDPOINT — print "https://<host>/v2" (scheme and /v2
# each exactly once). Use as the ibmcloud backup-recovery CLI service-url.
brs_endpoint_service_url() {
  local url
  url=$(brs_endpoint_url "${1:-}")
  [[ -n "${url}" ]] || return 0
  echo "${url}/v2"
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

# Derive the IBM Cloud API endpoint from a BRS instance endpoint URL.
# Usage: get_ibmcloud_api_endpoint BRS_ENDPOINT_OR_URL
# Returns: "test.cloud.ibm.com" when the BRS endpoint targets the test environment,
#          "cloud.ibm.com" otherwise.
#
# Examples:
#   32ea8bb2-fe6c-4712-b02c-25ddc33110b6.us-east.backup-recovery-tests.cloud.ibm.com
#     → test.cloud.ibm.com   (hostname contains "test.cloud.ibm.com")
#   32ea8bb2-fe6c-4712-b02c-25ddc33110b6.us-south.backup-recovery.cloud.ibm.com
#     → cloud.ibm.com
get_ibmcloud_api_endpoint() {
  local brs_endpoint="$1"
  if [[ "$brs_endpoint" == *"test.cloud.ibm.com"* ]]; then
    echo "test.cloud.ibm.com"
  else
    echo "cloud.ibm.com"
  fi
}
