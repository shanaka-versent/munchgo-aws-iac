#!/bin/bash
# Setup Kong Konnect Dedicated Cloud Gateway
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Creates a Konnect control plane with Dedicated Cloud Gateway,
# provisions the cloud gateway network, and configures Transit Gateway
# attachment for private connectivity to EKS backend services.
#
# Prerequisites:
#   1. A Konnect Personal Access Token (kpat_xxx)
#   2. EKS cluster deployed with Terraform (for VPC ID, Transit Gateway ID)
#   3. AWS Transit Gateway shared via RAM with Kong's account
#
# Usage:
#   export KONNECT_REGION="au"
#   export KONNECT_TOKEN="kpat_xxx..."
#   export TRANSIT_GATEWAY_ID="tgw-xxxxxxxxx"      # From terraform output
#   export RAM_SHARE_ARN="arn:aws:ram:..."          # From terraform output
#   export EKS_VPC_CIDR="10.0.0.0/16"              # Your VPC CIDR
#   ./scripts/01-setup-cloud-gateway.sh

set -euo pipefail

# Auto-source .env if it exists (contains KONNECT_TOKEN etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${CYAN}[CONFIG]${NC} $*"; }

CP_NAME="kong-cloud-gateway-eks"
DCGW_NETWORK_NAME="eks-backend-network"
DCGW_CIDR="192.168.0.0/16"
KONG_GW_VERSION="3.9"

# ---------------------------------------------------------------------------
# Auto-populate Transit Gateway values from Terraform outputs
# ---------------------------------------------------------------------------
populate_from_terraform() {
    local tf_dir="${SCRIPT_DIR}/../terraform"

    if [[ -d "${tf_dir}/.terraform" ]]; then
        log "Reading Transit Gateway values from Terraform outputs..."
        if [[ -z "${TRANSIT_GATEWAY_ID:-}" ]]; then
            TRANSIT_GATEWAY_ID=$(terraform -chdir="$tf_dir" output -raw transit_gateway_id 2>/dev/null || true)
        fi
        if [[ -z "${RAM_SHARE_ARN:-}" ]]; then
            RAM_SHARE_ARN=$(terraform -chdir="$tf_dir" output -raw ram_share_arn 2>/dev/null || true)
        fi
        if [[ -z "${EKS_VPC_CIDR:-}" ]]; then
            EKS_VPC_CIDR=$(terraform -chdir="$tf_dir" output -raw vpc_cidr 2>/dev/null || true)
        fi
    fi
}

# ---------------------------------------------------------------------------
# Validate environment variables
# ---------------------------------------------------------------------------
validate_env() {
    local missing=false

    if [[ -z "${KONNECT_REGION:-}" ]]; then
        error "KONNECT_REGION not set (e.g., us, eu, au)"
        missing=true
    fi
    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        error "KONNECT_TOKEN not set (Personal Access Token from Konnect)"
        missing=true
    fi

    if [[ "$missing" == true ]]; then
        echo ""
        echo "Usage:"
        echo "  1. Copy .env.example to .env and set KONNECT_REGION and KONNECT_TOKEN"
        echo "     cp .env.example .env"
        echo ""
        echo "  2. Run this script (Transit Gateway values are auto-read from Terraform):"
        echo "     ./scripts/02-setup-cloud-gateway.sh"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Create Control Plane
# ---------------------------------------------------------------------------
create_control_plane() {
    log "Step 1: Creating Konnect control plane: ${CP_NAME}"

    if [[ -n "${CONTROL_PLANE_ID:-}" ]]; then
        log "  Using existing control plane: ${CONTROL_PLANE_ID}"
        return
    fi

    CP_RESPONSE=$(curl -s -X POST \
        "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"${CP_NAME}\",
            \"cluster_type\": \"CLUSTER_TYPE_CONTROL_PLANE\",
            \"cloud_gateway\": true,
            \"labels\": {
                \"env\": \"poc\",
                \"type\": \"cloud-gateway\",
                \"managed-by\": \"script\"
            }
        }")

    CONTROL_PLANE_ID=$(echo "$CP_RESPONSE" | jq -r '.id')

    if [[ -z "$CONTROL_PLANE_ID" || "$CONTROL_PLANE_ID" == "null" ]]; then
        error "Failed to create control plane"
        error "Response: $CP_RESPONSE"
        exit 1
    fi

    log "  Control Plane ID: ${CONTROL_PLANE_ID}"
}

# ---------------------------------------------------------------------------
# Step 2: Create Cloud Gateway Network
# ---------------------------------------------------------------------------
create_network() {
    log "Step 2: Creating Cloud Gateway Network: ${DCGW_NETWORK_NAME}"

    # Get provider account ID for the region
    PROVIDER_ACCOUNTS=$(curl -s \
        "https://global.api.konghq.com/v2/cloud-gateways/provider-accounts" \
        -H "Authorization: Bearer $KONNECT_TOKEN")

    PROVIDER_ACCOUNT_ID=$(echo "$PROVIDER_ACCOUNTS" | jq -r \
        '.data[] | select(.provider == "aws") | .id' | head -1)

    if [[ -z "$PROVIDER_ACCOUNT_ID" || "$PROVIDER_ACCOUNT_ID" == "null" ]]; then
        warn "Could not find AWS provider account."
        warn "Available providers:"
        echo "$PROVIDER_ACCOUNTS" | jq -r '.data[] | "  \(.provider) (\(.id))"'
        warn "You may need to create the network manually in Konnect UI."
        return
    fi

    NETWORK_RESPONSE=$(curl -s -X POST \
        "https://global.api.konghq.com/v2/cloud-gateways/networks" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"${DCGW_NETWORK_NAME}\",
            \"cloud_gateway_provider_account_id\": \"${PROVIDER_ACCOUNT_ID}\",
            \"region\": \"ap-southeast-2\",
            \"availability_zones\": [\"apse2-az1\", \"apse2-az2\"],
            \"cidr_block\": \"${DCGW_CIDR}\"
        }")

    NETWORK_ID=$(echo "$NETWORK_RESPONSE" | jq -r '.id')

    if [[ -z "$NETWORK_ID" || "$NETWORK_ID" == "null" ]]; then
        error "Failed to create network"
        error "Response: $NETWORK_RESPONSE"
        warn "You may need to create this via Konnect UI instead."
        return
    fi

    log "  Network ID: ${NETWORK_ID}"
    log "  Network provisioning takes ~30 minutes. Check status in Konnect dashboard."
}

# ---------------------------------------------------------------------------
# Step 3: Create Data Plane Group Configuration
# ---------------------------------------------------------------------------
create_dp_group() {
    log "Step 3: Creating Data Plane Group Configuration"

    if [[ -z "${NETWORK_ID:-}" ]]; then
        warn "Network ID not available. Create data plane group manually in Konnect UI."
        return
    fi

    CONFIG_RESPONSE=$(curl -s -X PUT \
        "https://global.api.konghq.com/v2/cloud-gateways/configurations" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"control_plane_id\": \"${CONTROL_PLANE_ID}\",
            \"version\": \"${KONG_GW_VERSION}\",
            \"control_plane_geo\": \"au\",
            \"dataplane_groups\": [{
                \"provider\": \"aws\",
                \"region\": \"ap-southeast-2\",
                \"cloud_gateway_network_id\": \"${NETWORK_ID}\",
                \"autoscale\": {
                    \"kind\": \"autopilot\",
                    \"base_rps\": 100
                }
            }]
        }")

    CONFIG_ID=$(echo "$CONFIG_RESPONSE" | jq -r '.id // .message // "unknown"')
    log "  Configuration: $CONFIG_ID"
}

# ---------------------------------------------------------------------------
# Step 4: Share RAM with Kong's AWS account
# ---------------------------------------------------------------------------
share_ram_with_kong() {
    if [[ -z "${RAM_SHARE_ARN:-}" ]]; then
        warn "RAM_SHARE_ARN not set. Skipping RAM principal association."
        return
    fi

    log "Step 4: Sharing Transit Gateway with Kong's AWS account via RAM"

    # Fetch Kong's AWS account ID from Konnect provider accounts
    KONG_AWS_ACCOUNT_ID=$(curl -s \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        "https://global.api.konghq.com/v2/cloud-gateways/provider-accounts" \
        | jq -r '.data[] | select(.provider == "aws") | .provider_account_id' | head -1)

    if [[ -z "$KONG_AWS_ACCOUNT_ID" || "$KONG_AWS_ACCOUNT_ID" == "null" ]]; then
        warn "Could not determine Kong's AWS account ID from Konnect API."
        warn "Add Kong's AWS account as a RAM principal manually:"
        warn "  aws ram associate-resource-share --resource-share-arn ${RAM_SHARE_ARN} --principals <KONG_AWS_ACCOUNT_ID>"
        return
    fi

    log "  Kong's AWS Account ID: ${KONG_AWS_ACCOUNT_ID}"

    # Check if already associated
    EXISTING=$(aws ram get-resource-share-associations \
        --association-type PRINCIPAL \
        --resource-share-arns "${RAM_SHARE_ARN}" \
        --query "resourceShareAssociations[?associatedEntity=='${KONG_AWS_ACCOUNT_ID}'].status" \
        --output text 2>/dev/null || true)

    if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
        log "  RAM principal already associated (status: ${EXISTING})"
        return
    fi

    aws ram associate-resource-share \
        --resource-share-arn "${RAM_SHARE_ARN}" \
        --principals "${KONG_AWS_ACCOUNT_ID}" > /dev/null 2>&1

    log "  RAM share associated with Kong's AWS account"
}

# ---------------------------------------------------------------------------
# Step 5: Wait for network to be ready, then attach Transit Gateway
# ---------------------------------------------------------------------------
attach_transit_gateway() {
    if [[ -z "${TRANSIT_GATEWAY_ID:-}" || -z "${RAM_SHARE_ARN:-}" || -z "${EKS_VPC_CIDR:-}" ]]; then
        echo ""
        warn "Transit Gateway variables not set. Skipping TGW attachment."
        warn "To connect to EKS services, set up Transit Gateway manually:"
        warn "  1. Create Transit Gateway in your AWS account"
        warn "  2. Share via AWS RAM with Kong's account"
        warn "  3. Attach in Konnect UI: API Gateway → Network → Attach Transit Gateway"
        return
    fi

    if [[ -z "${NETWORK_ID:-}" ]]; then
        warn "Network ID not available. Attach Transit Gateway manually in Konnect UI."
        return
    fi

    # Wait for network to reach 'ready' state before attaching TGW
    log "Step 5: Waiting for Cloud Gateway Network to be ready..."
    local max_wait=2400  # 40 minutes
    local interval=30
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        NETWORK_STATE=$(curl -s \
            -H "Authorization: Bearer $KONNECT_TOKEN" \
            "https://global.api.konghq.com/v2/cloud-gateways/networks/${NETWORK_ID}" \
            | jq -r '.state')

        if [[ "$NETWORK_STATE" == "ready" ]]; then
            log "  Network is ready"
            break
        fi

        log "  Network state: ${NETWORK_STATE} (waited ${waited}s / ${max_wait}s)"
        sleep "$interval"
        waited=$((waited + interval))
    done

    if [[ "$NETWORK_STATE" != "ready" ]]; then
        warn "Network did not reach 'ready' state within ${max_wait}s."
        warn "Attach Transit Gateway manually once network is ready."
        return
    fi

    log "  Attaching Transit Gateway to Cloud Gateway Network"

    TGW_RESPONSE=$(curl -s -X POST \
        "https://global.api.konghq.com/v2/cloud-gateways/networks/${NETWORK_ID}/transit-gateways" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"eks-transit-gateway\",
            \"cidr_blocks\": [\"${EKS_VPC_CIDR}\"],
            \"transit_gateway_attachment_config\": {
                \"kind\": \"aws-transit-gateway-attachment\",
                \"transit_gateway_id\": \"${TRANSIT_GATEWAY_ID}\",
                \"ram_share_arn\": \"${RAM_SHARE_ARN}\"
            }
        }")

    TGW_ATT_ID=$(echo "$TGW_RESPONSE" | jq -r '.id // .message // "unknown"')
    log "  Transit Gateway attachment: $TGW_ATT_ID"

    if [[ "$TGW_ATT_ID" == "unknown" || "$TGW_ATT_ID" == "null" ]]; then
        warn "TGW attachment may have failed. Check Konnect UI."
        warn "Response: $TGW_RESPONSE"
        return
    fi

    # TGW auto_accept_shared_attachments is enabled in Terraform,
    # so Kong's attachment will be accepted automatically.
    log "  Transit Gateway attachment created. Auto-accept is enabled."
    log "  Waiting for attachment to complete..."

    local tgw_waited=0
    local tgw_max=600  # 10 minutes
    while [[ $tgw_waited -lt $tgw_max ]]; do
        TGW_STATE=$(curl -s \
            -H "Authorization: Bearer $KONNECT_TOKEN" \
            "https://global.api.konghq.com/v2/cloud-gateways/networks/${NETWORK_ID}/transit-gateways/${TGW_ATT_ID}" \
            | jq -r '.state')

        if [[ "$TGW_STATE" == "ready" ]]; then
            log "  Transit Gateway attachment is ready!"
            return
        fi

        log "  TGW attachment state: ${TGW_STATE} (waited ${tgw_waited}s)"
        sleep 30
        tgw_waited=$((tgw_waited + 30))
    done

    warn "TGW attachment did not reach 'ready' within ${tgw_max}s."
    warn "Check AWS Console: VPC → Transit Gateway Attachments"
    warn "If pending, accept manually. Auto-accept may require the TGW to be shared first."
}

# ---------------------------------------------------------------------------
# Print next steps
# ---------------------------------------------------------------------------
show_next_steps() {
    echo ""
    echo "=========================================="
    echo "  Cloud Gateway Setup Summary"
    echo "=========================================="
    echo ""
    echo "Control Plane ID: ${CONTROL_PLANE_ID:-'N/A'}"
    echo "Network ID:       ${NETWORK_ID:-'N/A'}"
    echo "Region:           ${KONNECT_REGION}"
    echo ""
    echo "Next steps:"
    echo "  1. Get the Istio Gateway NLB DNS:"
    echo "     ./scripts/03-post-terraform-setup.sh"
    echo ""
    echo "  2. Update deck/kong.yaml with the NLB hostname, then sync:"
    echo "     deck gateway sync deck/kong.yaml \\"
    echo "       --konnect-addr https://\${KONNECT_REGION}.api.konghq.com \\"
    echo "       --konnect-token \$KONNECT_TOKEN \\"
    echo "       --konnect-control-plane-name ${CP_NAME}"
    echo ""
    echo "  3. Verify data plane nodes:"
    echo "     https://cloud.konghq.com → Gateway Manager → Data Plane Nodes"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Kong Konnect Dedicated Cloud Gateway Setup"
    echo "=============================================="
    echo ""

    populate_from_terraform
    validate_env
    create_control_plane
    create_network
    create_dp_group
    share_ram_with_kong
    attach_transit_gateway
    show_next_steps
}

main "$@"
