#!/bin/bash

set -euo pipefail

# Script to wait for BRS source registration to refresh and discover namespaces
# This replaces the time_sleep resource with active polling of the BRS API.
#
# Important: source discovery in BRS is asynchronous. There is no verified CLI
# refresh operation wired here, so this script must only wait for eventual
# discovery and provide actionable diagnostics when discovery never appears.

TENANT_ID="$1"
INSTANCE_GUID="$2"
REGION="$3"
ENDPOINT_TYPE="$4"
MAX_ATTEMPTS="${5:-20}"  # Default 20 attempts = ~10 minutes with 30s sleep
# The binaries downloaded by the install-binaries script are located in the /tmp directory.
export PATH="$PATH:${6:-/tmp}"
SLEEP_DURATION=30
LAST_ERROR=""

if [ -z "$TENANT_ID" ] || [ -z "$INSTANCE_GUID" ] || [ -z "$REGION" ]; then
    echo "Error: TENANT_ID, INSTANCE_GUID, and REGION are required"
    echo "Usage: $0 <tenant_id> <instance_guid> <region> <endpoint_type> [max_attempts] [binaries_path]"
    exit 1
fi

if ! command -v ibmcloud >/dev/null 2>&1; then
    echo "Error: ibmcloud CLI not found in PATH: $PATH"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not found in PATH: $PATH"
    exit 1
fi

# Set default endpoint type if not provided
ENDPOINT_TYPE="${ENDPOINT_TYPE:-public}"

echo "Waiting for BRS source registration to refresh and discover namespaces..."
echo "Tenant ID: $TENANT_ID"
echo "Instance GUID: $INSTANCE_GUID"
echo "Region: $REGION"
echo "Endpoint Type: $ENDPOINT_TYPE"
echo "Max attempts: $MAX_ATTEMPTS (checking every ${SLEEP_DURATION}s)"

get_sources() {
    local output
    if ! output=$(ibmcloud brs protection-sources \
        --x-ibm-tenant-id "$TENANT_ID" \
        --instance-id "$INSTANCE_GUID" \
        --region "$REGION" \
        --endpoint-type "$ENDPOINT_TYPE" \
        --environment kKubernetes \
        --output json 2>&1); then
        LAST_ERROR="$output"
        return 1
    fi

    LAST_ERROR=""
    printf '%s\n' "$output"
}

COUNTER=0

while [[ $COUNTER -lt $MAX_ATTEMPTS ]]; do
    COUNTER=$((COUNTER + 1))

    echo "Attempt $COUNTER/$MAX_ATTEMPTS: Checking for discovered protection sources..."

    SOURCES_OUTPUT=""
    if SOURCES_OUTPUT=$(get_sources); then
        if ! echo "$SOURCES_OUTPUT" | jq empty >/dev/null 2>&1; then
            LAST_ERROR="Non-JSON response from ibmcloud brs protection-sources: $SOURCES_OUTPUT"
            echo "⏳ BRS API returned a non-JSON response, waiting before retry..."
        else
            SOURCE_COUNT=$(echo "$SOURCES_OUTPUT" | jq 'if type=="array" then length else 0 end')

            if [ "$SOURCE_COUNT" -gt 0 ]; then
                echo "✓ Source registration is now visible in BRS - discovered $SOURCE_COUNT protection source(s)"

                NODES_COUNT=$(echo "$SOURCES_OUTPUT" | jq '[.[] | (.nodes // []) | length] | add // 0')

                if [ "$NODES_COUNT" -gt 0 ]; then
                    echo "✓ Namespaces discovered: $NODES_COUNT namespace(s) found"
                    exit 0
                fi

                echo "⏳ Protection sources found but namespaces are not populated yet"
            else
                echo "⏳ No protection sources discovered yet, waiting for asynchronous BRS discovery..."
            fi
        fi
    else
        echo "⏳ Failed to query BRS protection sources, waiting before retry..."
        echo "Last command error: $LAST_ERROR"
    fi

    if [[ $COUNTER -lt $MAX_ATTEMPTS ]]; then
        echo "Waiting ${SLEEP_DURATION}s before next check..."
        sleep "$SLEEP_DURATION"
    fi
done

echo "✗ Error: Source discovery did not complete within $((MAX_ATTEMPTS * SLEEP_DURATION / 60)) minutes"
echo "BRS source registration exists, but protection sources/namespaces never became visible through the API."
if [ -n "$LAST_ERROR" ]; then
    echo "Last observed CLI/API error: $LAST_ERROR"
fi
echo "Manual UI refresh making the source appear suggests server-side discovery is asynchronous and not triggered by this module."
echo "Recommended action: add an initial stabilization delay before polling, or replace this wait step with a provider/API-backed readiness signal once BRS exposes a supported refresh/readiness operation."
exit 1

# Made with Bob
