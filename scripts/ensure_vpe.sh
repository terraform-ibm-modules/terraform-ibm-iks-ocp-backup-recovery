#!/bin/bash
# ensure_vpe.sh — Idempotent create-and-forget VPE gateway + reserved IPs.
#
# Creates an IBM Cloud VPC Virtual Private Endpoint gateway for a given service
# CRN, plus one reserved IP per subnet, then exits. Because Terraform tracks
# this only via a terraform_data resource (not via provider resources), the VPE
# and IPs are NEVER destroyed when `terraform destroy` runs — they are shared
# infrastructure that outlives any individual workspace.
#
# Idempotent: if a VPE with the given name already exists in the VPC, the
# script exits 0 without making any changes.
#
# Usage:
#   ensure_vpe.sh VPE_NAME VPC_ID SERVICE_CRN RESOURCE_GROUP_ID REGION \
#                 SECURITY_GROUP_ID SUBNET_IDS_COMMA_SEPARATED
#
# IBMCLOUD_API_KEY must be set as an environment variable.
#
# Outputs to stdout (one per line, for capture):
#   VPE_ID
#   <reserved_ip_id_zone1>
#   <reserved_ip_id_zone2>
#   ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common_utils.sh
source "${SCRIPT_DIR}/common_utils.sh"

if [ "$#" -lt 7 ]; then
  echo "Usage: $0 VPE_NAME VPC_ID SERVICE_CRN RESOURCE_GROUP_ID REGION SECURITY_GROUP_ID SUBNET_IDS" >&2
  exit 1
fi

if [ -z "${IBMCLOUD_API_KEY:-}" ]; then # pragma: allowlist secret
  echo "ERROR: IBMCLOUD_API_KEY is not set" >&2
  exit 1
fi

VPE_NAME="$1"
VPC_ID="$2"
SERVICE_CRN="$3"
RESOURCE_GROUP_ID="$4"
REGION="$5"
SECURITY_GROUP_ID="$6"
# Comma-separated list of subnet IDs
SUBNET_IDS_RAW="$7"

echo "=== ensure_vpe.sh ===" >&2
echo "VPE name:       ${VPE_NAME}" >&2
echo "VPC:            ${VPC_ID}" >&2
echo "Service CRN:    ${SERVICE_CRN}" >&2
echo "Region:         ${REGION}" >&2
echo "Security group: ${SECURITY_GROUP_ID}" >&2
echo "Subnets:        ${SUBNET_IDS_RAW}" >&2

# ---------------------------------------------------------------------------
# 0. Authenticate and Target
# ---------------------------------------------------------------------------
echo "Authenticating via ibmcloud CLI..." >&2
ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r "${REGION}" -g "${RESOURCE_GROUP_ID}" -q >&2

# ---------------------------------------------------------------------------
# 1. Check if VPE already exists (idempotent guard)
# ---------------------------------------------------------------------------
echo "Checking for existing VPE '${VPE_NAME}' in VPC '${VPC_ID}'..." >&2
existing=$(ibmcloud is endpoint-gateways --output json | \
  jq -r ".[] | select(.name == \"${VPE_NAME}\" and .vpc.id == \"${VPC_ID}\") | .id")

if [ -n "${existing}" ]; then
  echo "VPE '${VPE_NAME}' already exists (id=${existing}) — skipping creation." >&2
  echo "${existing}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Create the VPE gateway
# ---------------------------------------------------------------------------
echo "Creating VPE gateway '${VPE_NAME}'..." >&2

vpe_body=$(ibmcloud is endpoint-gateway-create \
  --name "${VPE_NAME}" \
  --vpc "${VPC_ID}" \
  --target "${SERVICE_CRN}" \
  --resource-group-id "${RESOURCE_GROUP_ID}" \
  --sg "${SECURITY_GROUP_ID}" \
  --output json)

VPE_ID=$(echo "${vpe_body}" | jq -r '.id')
echo "✓ VPE created: ${VPE_ID}" >&2

# ---------------------------------------------------------------------------
# 3. Create a reserved IP in each subnet and bind it to the VPE
# ---------------------------------------------------------------------------
IFS=',' read -ra SUBNETS <<< "${SUBNET_IDS_RAW}"
for subnet_id in "${SUBNETS[@]}"; do
  subnet_id="${subnet_id// /}"   # trim spaces
  [ -z "${subnet_id}" ] && continue

  echo "Creating reserved IP in subnet ${subnet_id}..." >&2

  rip_body=$(ibmcloud is subnet-reserved-ip-create "${subnet_id}" \
    --auto-delete false \
    --output json)

  RIP_ID=$(echo "${rip_body}" | jq -r '.id')
  echo "✓ Reserved IP ${RIP_ID} in subnet ${subnet_id}" >&2

  # Bind the reserved IP to the VPE
  ibmcloud is endpoint-gateway-reserved-ip-bind "${VPE_ID}" --rip "${RIP_ID}" --output json >/dev/null

  echo "✓ Reserved IP ${RIP_ID} bound to VPE ${VPE_ID}" >&2
  echo "${RIP_ID}"
done

echo "✓ VPE ${VPE_NAME} ready." >&2
echo "${VPE_ID}"
