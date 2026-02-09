#!/bin/bash
# Kong Cloud Gateway on EKS - Automated Stack Teardown
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Tears down the full stack: EKS infrastructure, Istio Gateway, Ambient mesh,
# and Kong Cloud Gateway in Konnect (via API).
#
# DESTRUCTION ORDER:
# ==================
# 1. Delete Istio Gateway resource (triggers NLB deprovisioning via LB Controller)
# 2. Wait for Internal NLB to be fully deprovisioned
# 3. Delete ArgoCD applications (cascade deletes Istio components, apps)
# 4. Cleanup Istio CRDs and remaining K8s resources
# 5. Delete Kong Cloud Gateway in Konnect via API (config, network, control plane)
# 6. Wait for Kong's TGW attachment to detach from our Transit Gateway
# 7. Run terraform destroy (handles EKS, VPC, Transit Gateway, RAM share, CloudFront + WAF)
# 8. Cleanup orphaned CloudFront CloudFormation stacks (safety net)
#
# WHY THIS ORDER:
# - The Istio Gateway creates an internal NLB via the AWS LB Controller.
#   If we delete EKS before the NLB is deprovisioned, the NLB and its
#   ENIs will be orphaned, blocking VPC deletion in terraform destroy.
# - Kong Cloud Gateway attaches its own VPC to our Transit Gateway.
#   Terraform cannot delete the TGW while Kong's attachment exists.
#   We must delete the Konnect network first and wait for the TGW
#   attachment to be fully removed before running terraform destroy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

# Auto-source .env if it exists (contains KONNECT_TOKEN etc.)
ENV_FILE="${REPO_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }

# Konnect resource names (must match 02-setup-cloud-gateway.sh)
CP_NAME="kong-cloud-gateway-eks"
DCGW_NETWORK_NAME="eks-backend-network"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    log "Running pre-flight checks..."

    for cmd in kubectl aws terraform jq; do
        if ! command -v "$cmd" &>/dev/null; then
            error "$cmd is required but not installed."
            exit 1
        fi
    done

    if ! kubectl cluster-info &>/dev/null; then
        warn "Cannot connect to Kubernetes cluster. Skipping K8s cleanup steps."
        return 1
    fi

    log "Pre-flight checks passed."
    return 0
}

# ---------------------------------------------------------------------------
# Step 1: Delete Istio Gateway (triggers NLB deprovisioning)
# ---------------------------------------------------------------------------
delete_istio_gateway() {
    log "Step 1: Deleting Istio Gateway resource (triggers NLB removal)..."

    # Delete the Gateway resource first -- this tells the LB Controller
    # to deprovision the internal NLB that Kong connects to via Transit GW
    if kubectl get gateway kong-cloud-gw-gateway -n istio-ingress &>/dev/null; then
        kubectl delete gateway kong-cloud-gw-gateway -n istio-ingress --timeout=120s 2>/dev/null || true
        log "Istio Gateway deleted. NLB deprovisioning initiated."
    else
        log "Istio Gateway not found (already deleted or not deployed)."
    fi

    # Also delete any HTTPRoutes to clean up references
    if kubectl get httproute -n gateway-health &>/dev/null 2>&1; then
        kubectl delete httproute --all -n gateway-health --timeout=60s 2>/dev/null || true
    fi
    if kubectl get httproute -n sample-apps &>/dev/null 2>&1; then
        kubectl delete httproute --all -n sample-apps --timeout=60s 2>/dev/null || true
    fi
    if kubectl get httproute -n api-services &>/dev/null 2>&1; then
        kubectl delete httproute --all -n api-services --timeout=60s 2>/dev/null || true
    fi

    log "Gateway and HTTPRoute resources deleted."
}

# ---------------------------------------------------------------------------
# Step 2: Wait for NLB to be fully deprovisioned
# ---------------------------------------------------------------------------
wait_for_nlb_cleanup() {
    log "Step 2: Waiting for Internal NLB to be deprovisioned..."

    # Check if any LoadBalancer services remain (created by Istio Gateway)
    local lb_services
    lb_services=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' || true)

    if [[ -n "$lb_services" ]]; then
        warn "Found remaining LoadBalancer services:"
        echo "$lb_services" | while read -r svc; do echo "  - $svc"; done

        # Force delete any remaining LB services
        echo "$lb_services" | while read -r svc; do
            local ns="${svc%%/*}"
            local name="${svc##*/}"
            kubectl delete svc "$name" -n "$ns" --timeout=120s 2>/dev/null || true
        done
    fi

    # Wait for AWS to fully remove the NLB and release ENIs
    # This prevents "DependencyViolation" errors during terraform destroy
    log "Waiting 90s for AWS to fully deprovision NLB and release ENIs..."
    sleep 90
    log "NLB cleanup wait complete."
}

# ---------------------------------------------------------------------------
# Step 3: Delete ArgoCD applications (cascade deletes everything)
# ---------------------------------------------------------------------------
delete_argocd_apps() {
    log "Step 3: Deleting ArgoCD applications..."

    if kubectl get app cloud-gateway-root -n argocd &>/dev/null; then
        kubectl delete app cloud-gateway-root -n argocd --timeout=300s 2>/dev/null || true
        log "Waiting for ArgoCD cascade deletion (Istio components, apps)..."
        kubectl wait --for=delete app/cloud-gateway-root -n argocd --timeout=300s 2>/dev/null || true
    fi

    # Safety net - delete any remaining ArgoCD apps
    local remaining_apps
    remaining_apps=$(kubectl get app -n argocd -o name 2>/dev/null || true)
    if [[ -n "$remaining_apps" ]]; then
        warn "Deleting remaining ArgoCD apps..."
        echo "$remaining_apps" | while read -r app; do
            kubectl delete "$app" -n argocd --timeout=120s 2>/dev/null || true
        done
    fi

    log "ArgoCD applications deleted."
}

# ---------------------------------------------------------------------------
# Step 4: Cleanup Istio CRDs and K8s namespaces
# ---------------------------------------------------------------------------
cleanup_k8s_resources() {
    log "Step 4: Cleaning up Istio and K8s resources..."

    # Delete application namespaces
    for ns in istio-ingress gateway-health sample-apps api-services; do
        if kubectl get ns "$ns" &>/dev/null; then
            log "Deleting namespace: $ns"
            kubectl delete ns "$ns" --timeout=120s 2>/dev/null || true
        fi
    done

    # Delete Istio system namespace (contains istiod, cni, ztunnel)
    if kubectl get ns istio-system &>/dev/null; then
        log "Deleting namespace: istio-system"
        kubectl delete ns istio-system --timeout=180s 2>/dev/null || true
    fi

    # Cleanup Gateway API CRDs (may have finalizers)
    log "Cleaning up Gateway API CRDs..."
    for crd in gateways.gateway.networking.k8s.io \
               httproutes.gateway.networking.k8s.io \
               referencegrants.gateway.networking.k8s.io \
               gatewayclasses.gateway.networking.k8s.io \
               grpcroutes.gateway.networking.k8s.io \
               tcproutes.gateway.networking.k8s.io \
               tlsroutes.gateway.networking.k8s.io \
               udproutes.gateway.networking.k8s.io \
               backendtlspolicies.gateway.networking.k8s.io \
               backendlbpolicies.gateway.networking.k8s.io; do
        if kubectl get crd "$crd" &>/dev/null; then
            kubectl delete crd "$crd" --timeout=60s 2>/dev/null || true
        fi
    done

    # Cleanup Istio CRDs
    log "Cleaning up Istio CRDs..."
    kubectl get crd -o name 2>/dev/null | grep -E 'istio\.io|tetrate\.io' | while read -r crd; do
        kubectl delete "$crd" --timeout=60s 2>/dev/null || true
    done

    log "K8s cleanup complete."
}

# ---------------------------------------------------------------------------
# Step 6: Wait for Kong's TGW attachment to be removed
# ---------------------------------------------------------------------------
# After deleting the Konnect network, Kong's VPC attachment to our TGW is
# removed asynchronously. We must wait for it to disappear before terraform
# can delete the Transit Gateway.
wait_for_kong_tgw_detach() {
    log "Step 6: Waiting for Kong's TGW attachment to detach from our Transit Gateway..."

    # Get our Transit Gateway ID from terraform state
    local tgw_id
    tgw_id=$(cd "$TERRAFORM_DIR" && terraform output -raw transit_gateway_id 2>/dev/null || true)

    if [[ -z "$tgw_id" ]]; then
        warn "  Could not determine Transit Gateway ID. Skipping TGW attachment wait."
        return
    fi

    log "  Transit Gateway: ${tgw_id}"

    # Poll for non-deleted attachments (excluding our own EKS attachment which
    # terraform will handle). Kong's attachment comes from a different account.
    local max_wait=300  # 5 minutes max
    local elapsed=0
    local interval=15

    while [[ $elapsed -lt $max_wait ]]; do
        local attachments
        attachments=$(aws ec2 describe-transit-gateway-attachments \
            --filters "Name=transit-gateway-id,Values=${tgw_id}" \
            --query 'TransitGatewayAttachments[?State!=`deleted` && State!=`deleting`].TransitGatewayAttachmentId' \
            --output text 2>/dev/null || true)

        # Count non-empty attachments (our EKS one may already be gone from K8s cleanup)
        local count=0
        if [[ -n "$attachments" ]]; then
            count=$(echo "$attachments" | wc -w | tr -d ' ')
        fi

        if [[ $count -eq 0 ]]; then
            log "  All TGW attachments removed."
            return
        fi

        # If only our own EKS attachment remains, that's fine - terraform will handle it
        local our_attachment
        our_attachment=$(cd "$TERRAFORM_DIR" && terraform state show 'aws_ec2_transit_gateway_vpc_attachment.eks' 2>/dev/null | grep 'id ' | awk '{print $NF}' | tr -d '"' || true)
        if [[ $count -eq 1 && "$attachments" == "$our_attachment" ]]; then
            log "  Only our EKS attachment remains (terraform will handle it)."
            return
        fi

        log "  Still ${count} attachment(s) active: ${attachments}. Waiting ${interval}s... (${elapsed}s/${max_wait}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    warn "  Timed out waiting for Kong's TGW attachment to detach after ${max_wait}s."
    warn "  Terraform destroy may fail on the Transit Gateway. If so, re-run destroy."
}

# ---------------------------------------------------------------------------
# Step 7: Terraform destroy
# ---------------------------------------------------------------------------
terraform_destroy() {
    log "Step 7: Running terraform destroy (EKS, VPC, Transit Gateway, CloudFront + WAF)..."

    cd "$TERRAFORM_DIR"

    if [[ ! -d ".terraform" ]]; then
        terraform init
    fi

    # Pass terraform.tfvars if it exists (contains kong_cloud_gateway_domain for CloudFront)
    local tf_args="-auto-approve"
    if [[ -f "terraform.tfvars" ]]; then
        tf_args="-var-file=terraform.tfvars -auto-approve"
    fi

    terraform destroy $tf_args

    log "Terraform destroy complete."
}

# ---------------------------------------------------------------------------
# Step 8: Cleanup orphaned CloudFront CloudFormation stacks (safety net)
# ---------------------------------------------------------------------------
# The CloudFront distribution is deployed via CloudFormation (for origin mTLS
# support). If terraform destroy fails to clean it up, this step removes it.
cleanup_cloudfront_cfn_stacks() {
    log "Step 8: Checking for orphaned CloudFront CloudFormation stacks..."

    local stack_name="kong-gw-poc-cloudfront-dist"
    local stack_status
    stack_status=$(aws cloudformation describe-stacks --stack-name "$stack_name" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

    if [[ "$stack_status" != "NOT_FOUND" ]]; then
        log "  Found CloudFormation stack '${stack_name}' (status: ${stack_status})"

        if [[ "$stack_status" == "DELETE_FAILED" || "$stack_status" == "ROLLBACK_COMPLETE" ]]; then
            log "  Deleting stack in ${stack_status} state..."
            aws cloudformation delete-stack --stack-name "$stack_name" || true
        elif [[ "$stack_status" != "DELETE_IN_PROGRESS" && "$stack_status" != "DELETE_COMPLETE" ]]; then
            log "  Deleting CloudFront CloudFormation stack..."
            aws cloudformation delete-stack --stack-name "$stack_name" || true
        fi

        log "  Waiting for stack deletion..."
        aws cloudformation wait stack-delete-complete --stack-name "$stack_name" 2>/dev/null || true
        log "  CloudFront CloudFormation stack cleaned up."
    else
        log "  No orphaned CloudFormation stacks found."
    fi
}

# ---------------------------------------------------------------------------
# Step 5: Delete Kong Cloud Gateway in Konnect (via API)
# ---------------------------------------------------------------------------
# Deletion order:
#   1. Delete control plane (cascades to delete configurations + data plane groups)
#   2. Wait for data plane groups to fully terminate
#   3. Delete Transit Gateway attachments from the network
#   4. Delete Cloud Gateway network
#
# NOTE: The Konnect configurations API does not support DELETE. Deleting the
# control plane cascades to terminate all associated data plane groups.
# The network can only be deleted after all referencing data plane groups are gone.
#
# IMPORTANT: Must run BEFORE terraform destroy. Kong Cloud Gateway creates a
# VPC attachment to our Transit Gateway. Terraform cannot delete the TGW until
# Kong's attachment is removed, which happens when we delete the Konnect network.
#
# Requires KONNECT_REGION and KONNECT_TOKEN (from .env)
# ---------------------------------------------------------------------------
delete_konnect_resources() {
    log "Step 5: Deleting Kong Cloud Gateway resources in Konnect..."

    if [[ -z "${KONNECT_REGION:-}" || -z "${KONNECT_TOKEN:-}" ]]; then
        warn "KONNECT_REGION or KONNECT_TOKEN not set. Skipping Konnect cleanup."
        warn "Delete Cloud Gateway manually: https://cloud.konghq.com → Gateway Manager"
        return
    fi

    local regional_api="https://${KONNECT_REGION}.api.konghq.com"
    local global_api="https://global.api.konghq.com"
    local auth_header="Authorization: Bearer ${KONNECT_TOKEN}"

    # --- Find control plane by name ---
    log "  Looking up control plane: ${CP_NAME}"
    local cp_list
    cp_list=$(curl -s "${regional_api}/v2/control-planes?filter%5Bname%5D=${CP_NAME}" \
        -H "$auth_header")
    local cp_id
    cp_id=$(echo "$cp_list" | jq -r '.data[0].id // empty')

    if [[ -z "$cp_id" ]]; then
        log "  Control plane '${CP_NAME}' not found. Skipping to network cleanup."
    fi

    # --- Delete control plane (cascades to data plane groups) ---
    if [[ -n "$cp_id" ]]; then
        log "  Deleting control plane: ${cp_id} (cascades to data plane groups)..."
        local cp_delete_resp
        cp_delete_resp=$(curl -s -w "\n%{http_code}" -X DELETE \
            "${regional_api}/v2/control-planes/${cp_id}" \
            -H "$auth_header")
        local cp_http_code
        cp_http_code=$(echo "$cp_delete_resp" | tail -1)

        if [[ "$cp_http_code" == "204" || "$cp_http_code" == "200" ]]; then
            log "  Control plane deleted."
        else
            warn "  Control plane deletion returned HTTP ${cp_http_code}."
            warn "  Check: https://cloud.konghq.com → Gateway Manager"
        fi

        # Wait for data plane groups to terminate (they reference the network)
        log "  Waiting for data plane groups to terminate..."
        local dp_max_wait=180  # 3 minutes
        local dp_elapsed=0
        local dp_interval=15

        while [[ $dp_elapsed -lt $dp_max_wait ]]; do
            local dp_states
            dp_states=$(curl -s "${global_api}/v2/cloud-gateways/configurations?filter%5Bcontrol_plane_id%5D=${cp_id}" \
                -H "$auth_header" | jq -r '[.data[].dataplane_groups[]?.state] | join(",")' 2>/dev/null || true)

            if [[ -z "$dp_states" ]]; then
                log "  All data plane groups terminated."
                break
            fi

            log "  Data plane group states: ${dp_states}. Waiting ${dp_interval}s... (${dp_elapsed}s/${dp_max_wait}s)"
            sleep "$dp_interval"
            dp_elapsed=$((dp_elapsed + dp_interval))
        done

        if [[ $dp_elapsed -ge $dp_max_wait ]]; then
            warn "  Timed out waiting for data plane groups to terminate."
        fi
    fi

    # --- Find and delete network + transit gateway attachments ---
    log "  Looking up network: ${DCGW_NETWORK_NAME}"
    local networks
    networks=$(curl -s "${global_api}/v2/cloud-gateways/networks" \
        -H "$auth_header")
    local network_id
    network_id=$(echo "$networks" | jq -r \
        ".data[] | select(.name == \"${DCGW_NETWORK_NAME}\") | .id" | head -1)

    if [[ -n "$network_id" ]]; then
        # Delete transit gateway attachments first
        log "  Deleting Transit Gateway attachments from network ${network_id}..."
        local tgw_list
        tgw_list=$(curl -s "${global_api}/v2/cloud-gateways/networks/${network_id}/transit-gateways" \
            -H "$auth_header")
        local tgw_ids
        tgw_ids=$(echo "$tgw_list" | jq -r '.data[].id // empty' 2>/dev/null || true)

        if [[ -n "$tgw_ids" ]]; then
            echo "$tgw_ids" | while read -r tgw_id; do
                [[ -z "$tgw_id" ]] && continue
                curl -s -X DELETE \
                    "${global_api}/v2/cloud-gateways/networks/${network_id}/transit-gateways/${tgw_id}" \
                    -H "$auth_header" >/dev/null 2>&1 || true
                log "  Deleted transit gateway attachment: ${tgw_id}"
            done
        else
            log "  No transit gateway attachments found."
        fi

        # Delete the network
        log "  Deleting network: ${network_id}"
        local delete_resp
        delete_resp=$(curl -s -w "\n%{http_code}" -X DELETE \
            "${global_api}/v2/cloud-gateways/networks/${network_id}" \
            -H "$auth_header")
        local http_code
        http_code=$(echo "$delete_resp" | tail -1)

        if [[ "$http_code" == "204" || "$http_code" == "200" || "$http_code" == "202" ]]; then
            log "  Network deletion initiated."
        else
            warn "  Network deletion returned HTTP ${http_code}. It may still be deprovisioning."
            warn "  Check: https://cloud.konghq.com → Gateway Manager → Networks"
        fi
    else
        log "  Network '${DCGW_NETWORK_NAME}' not found."
    fi

    log "  Konnect cleanup complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "================================================="
    echo "  Kong Cloud Gateway EKS - Stack Teardown"
    echo "  (Istio Gateway + Ambient Mesh + Kong Cloud GW)"
    echo "================================================="
    echo ""
    echo "This will destroy:"
    echo "  - Kong Cloud Gateway in Konnect (control plane, network, config)"
    echo "  - Istio Gateway (internal NLB)"
    echo "  - Istio Ambient mesh (istiod, cni, ztunnel)"
    echo "  - All backend applications"
    echo "  - ArgoCD and all managed apps"
    echo "  - CloudFront distribution + WAF Web ACL"
    echo "  - EKS cluster, VPC, Transit Gateway"
    echo ""

    local k8s_available=true
    preflight_checks || k8s_available=false

    if [[ "$k8s_available" == true ]]; then
        delete_istio_gateway
        wait_for_nlb_cleanup
        delete_argocd_apps
        cleanup_k8s_resources
    else
        warn "Skipping K8s cleanup. Running terraform destroy directly."
        warn "If terraform fails due to orphaned NLBs, manually delete them in AWS Console:"
        warn "  EC2 -> Load Balancers -> Delete internal NLBs"
        warn "  Then re-run terraform destroy."
    fi

    # Delete Konnect resources BEFORE terraform destroy.
    # Kong's TGW attachment must be removed before terraform can delete the TGW.
    delete_konnect_resources
    wait_for_kong_tgw_detach

    terraform_destroy
    cleanup_cloudfront_cfn_stacks

    echo ""
    log "Full stack teardown complete (EKS + CloudFront + WAF + Konnect)."
    echo ""
}

main "$@"
