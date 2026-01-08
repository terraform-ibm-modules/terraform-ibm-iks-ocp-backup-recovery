#!/bin/bash
set -euo pipefail

# --- Configuration & Validation ---
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 URL TENANT ENDPOINT_TYPE [PROTECTION_GROUP_ID] [REGISTRATION_ID]"
    exit 1
fi

URL=$1
TENANT=$2
ENDPOINT_TYPE=$3
PROTECTION_GROUP_ID=${4:-}
REGISTRATION_ID=${5:-}

# --- Internal Functions ---

call_api() {
    local method=$1
    local path=$2
    shift 2
    curl --retry 3 -s -X "$method" "${URL}${path}" \
        -H "Authorization: Bearer ${iam_token}" \
        -H "X-IBM-Tenant-Id: ${TENANT}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "$@"
}

get_iam_token() {
    local iam_endpoint="${IBMCLOUD_IAM_API_ENDPOINT:-"iam.cloud.ibm.com"}"
    iam_endpoint=${iam_endpoint#https://}

    if [[ "$iam_endpoint" == "iam.cloud.ibm.com" && "$ENDPOINT_TYPE" == "private" ]]; then
        iam_endpoint="private.${iam_endpoint}"
    fi

    local response
    # Added pragma to satisfy secret scanners
    response=$(curl --retry 3 -s -X POST "https://${iam_endpoint}/identity/token" --header 'Content-Type: application/x-www-form-urlencoded' --header 'Accept: application/json' --data-urlencode 'grant_type=urn:ibm:params:oauth:grant-type:apikey' --data-urlencode "apikey=$API_KEY") # pragma: allowlist secret

    if echo "$response" | jq -e 'has("errorMessage")' > /dev/null; then
        echo "IAM Error: $(echo "$response" | jq -r '.errorMessage')" >&2
        exit 1
    fi
    echo "$response" | jq -r '.access_token'
}

pause_protection_group() {
    local pg_id=$1
    echo "Fetching details for PG: $pg_id"

    local details name policy obj_id obj_name
    # SC2155: Declaring and assigning separately
    details=$(call_api "GET" "/v2/data-protect/protection-groups/${pg_id}")
    name=$(echo "$details" | jq -r '.name')
    policy=$(echo "$details" | jq -r '.policyId')
    obj_id=$(echo "$details" | jq -r '.kubernetesParams.objects[0].id')
    obj_name=$(echo "$details" | jq -r '.kubernetesParams.objects[0].name')

    echo "Pausing protection group: $name..."
    call_api "PUT" "/v2/data-protect/protection-groups/${pg_id}" --data-raw "{
        \"name\": \"$name\",
        \"policyId\": \"$policy\",
        \"environment\": \"kKubernetes\",
        \"kubernetesParams\": { \"objects\": [ { \"id\": $obj_id, \"name\": \"$obj_name\" } ] },
        \"isPaused\": true
    }" > /dev/null
}

cancel_and_wait_jobs() {
    local pg_id=$1
    local run_data run_id task_id

    run_data=$(call_api "GET" "/v2/data-protect/protection-groups/${pg_id}/runs" -d 'excludeNonRestorableRuns=false')
    run_id=$(echo "$run_data" | jq -r '.runs[0].id // empty')
    task_id=$(echo "$run_data" | jq -r '.runs[0].archivalInfo.archivalTargetResults[0].archivalTaskId // empty')

    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        echo "No active runs found to cancel."
        return
    fi

    echo "Canceling job $run_id..."
    call_api "POST" "/v2/data-protect/protection-groups/${pg_id}/runs/actions" --data-raw "{
        \"action\": \"Cancel\",
        \"cancelParams\": [ { \"runId\": \"$run_id\", \"localTaskId\": \"$task_id\" } ]
    }" > /dev/null

    while true; do
        local status
        status=$(call_api "GET" "/v2/data-protect/protection-groups/${pg_id}/runs" -d 'excludeNonRestorableRuns=false' | \
                 jq -r '.runs[0].archivalInfo.archivalTargetResults[0].status')

        echo "Job status: $status"
        [[ "$status" == "Canceled" || "$status" == "Succeeded" || "$status" == "Failed" ]] && break
        sleep 10
    done
}

expire_snapshots() {
    local reg_id=$1
    local raw ids

    echo "Fetching snapshots for Registration: $reg_id"
    raw=$(call_api "GET" "/v2/data-protect/objects/${reg_id}/snapshots")
    ids=$(echo "$raw" | jq -r '.snapshots[]?.id // empty')

    for snap_id in $ids; do
        echo -n "Expiring snapshot $snap_id... "
        call_api "PUT" "/v2/data-protect/objects/${reg_id}/snapshots/${snap_id}" --data-raw '{
            "setLegalHold": false,
            "dataLockType": "Compliance",
            "expiryTimeSecs": 0
        }' -o /dev/null -w "Status: %{http_code}\n"
    done
}

delete_protection_group() {
    local pg_id=$1
    echo "Deleting protection group: $pg_id"
    local http_code
    http_code=$(call_api "DELETE" "/v2/data-protect/protection-groups/${pg_id}?deleteSnapshots=true" -o /dev/null -w "%{http_code}")

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "Delete successful."
    else
        echo "Delete failed with status: $http_code" >&2
        exit 1
    fi
}

# --- Main Execution ---

# 1. Obtain Token (Secret scanning pragma applied inside function)
iam_token=$(get_iam_token)

# 2. Handle Protection Group Pause/Cancel
if [[ -n "$PROTECTION_GROUP_ID" ]]; then
    pause_protection_group "$PROTECTION_GROUP_ID"
    cancel_and_wait_jobs "$PROTECTION_GROUP_ID"
fi

# 3. Handle Snapshot Expiry
if [[ -n "$REGISTRATION_ID" ]]; then
    expire_snapshots "$REGISTRATION_ID"
fi

# 4. Final Deletion
if [[ -n "$PROTECTION_GROUP_ID" ]]; then
    delete_protection_group "$PROTECTION_GROUP_ID"
fi

echo "Cleanup complete."
