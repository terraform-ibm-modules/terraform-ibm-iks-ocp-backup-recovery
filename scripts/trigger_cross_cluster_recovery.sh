#!/bin/bash
set -euo pipefail

if [ "$#" -lt 9 ]; then
  echo "Usage: $0 URL TENANT ENDPOINT_TYPE INSTANCE_ID SOURCE_PG_ID TARGET_SOURCE_ID SNAPSHOT_ID API_KEY RECOVERY_NAME [BINARIES_PATH]" >&2
  exit 1
fi

URL=$1
TENANT=$2
ENDPOINT_TYPE=$3
# shellcheck disable=SC2034  # Used in API URL construction
INSTANCE_ID=$4
SOURCE_PG_ID=$5
TARGET_SOURCE_ID=$6
SNAPSHOT_ID=$7
API_KEY=$8
RECOVERY_NAME=$9
BINARIES_PATH=${10:-/tmp}

export PATH="${PATH}:${BINARIES_PATH}"

get_iam_token() {
  local iam_endpoint="${IBMCLOUD_IAM_API_ENDPOINT:-iam.cloud.ibm.com}"
  iam_endpoint=${iam_endpoint#https://}

  if [[ "$iam_endpoint" == "iam.cloud.ibm.com" && "$ENDPOINT_TYPE" == "private" ]]; then
    iam_endpoint="private.${iam_endpoint}"
  fi

  local response
  response=$(curl --retry 3 -s -X POST "https://${iam_endpoint}/identity/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --header 'Accept: application/json' \
    --data-urlencode 'grant_type=urn:ibm:params:oauth:grant-type:apikey' \
    --data-urlencode "apikey=${API_KEY}")  # pragma: allowlist secret

  if echo "$response" | jq -e 'has("errorMessage")' > /dev/null; then
    echo "IAM Error: $(echo "$response" | jq -r '.errorMessage')" >&2
    exit 1
  fi

  echo "$response" | jq -r '.access_token'
}

echo "=== Cross-Cluster Recovery ===" >&2
echo "Source PG ID: ${SOURCE_PG_ID}" >&2
echo "Target Source ID: ${TARGET_SOURCE_ID}" >&2
echo "Snapshot ID: ${SNAPSHOT_ID}" >&2

IAM_TOKEN=$(get_iam_token)

# Create recovery request with correct structure based on UI-generated recovery
# The key is: kubernetesParams.recoverNamespaceParams.kubernetesTargetParams.recoveryTargetConfig
RECOVERY_PAYLOAD=$(cat <<PAYLOAD
{
  "name": "${RECOVERY_NAME}",
  "snapshotEnvironment": "kKubernetes",
  "kubernetesParams": {
    "recoveryAction": "RecoverNamespaces",
    "objects": [{
      "snapshotId": "${SNAPSHOT_ID}",
      "protectionGroupId": "${SOURCE_PG_ID}"
    }],
    "recoverNamespaceParams": {
      "targetEnvironment": "kKubernetes",
      "kubernetesTargetParams": {
        "objects": [{
          "snapshotId": "${SNAPSHOT_ID}",
          "protectionGroupId": "${SOURCE_PG_ID}"
        }],
        "recoveryTargetConfig": {
          "recoverToNewSource": true,
          "newSourceConfig": {
            "source": {
              "id": ${TARGET_SOURCE_ID}
            }
          }
        },
        "renameRecoveredNamespacesParams": {
          "prefix": "restored-"
        }
      }
    }
  }
}
PAYLOAD
)

echo "Triggering recovery to target cluster..." >&2
echo "DEBUG: Payload being sent:" >&2
echo "$RECOVERY_PAYLOAD" | jq '.' >&2
echo "" >&2

response=$(curl --retry 3 -s -w "\n%{http_code}" -X POST "${URL}/v2/data-protect/recoveries" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "X-IBM-Tenant-Id: ${TENANT}" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d "${RECOVERY_PAYLOAD}")

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "Recovery API Error: HTTP $http_code" >&2
  echo "Response: $body" >&2
  exit 1
fi

echo "✓ Recovery triggered successfully!" >&2
echo "$body" | jq '.'

# Made with Bob
