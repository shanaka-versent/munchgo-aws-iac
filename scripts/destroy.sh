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

# Konnect resource names — must match terraform/variables.tf defaults and 02-setup-cloud-gateway.sh
CP_NAME="${KONNECT_CONTROL_PLANE_NAME:-MunchGo}"
DCGW_NETWORK_NAME="munchgo-eks-network"

# Konnect API base URLs (derived from KONNECT_REGION)
KONNECT_GLOBAL_API="https://global.api.konghq.com"
KONNECT_REGIONAL_API="https://${KONNECT_REGION:-au}.api.konghq.com"

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

    # Export Konnect token so the provider can authenticate during destroy
    if [[ -n "${KONNECT_TOKEN:-}" ]]; then
        export TF_VAR_konnect_token="${KONNECT_TOKEN}"
    fi

    # Check if the Transit Gateway is shared with other projects.
    # If non-MunchGo VPC attachments exist, remove the TGW from state
    # instead of trying to delete it (which would fail and disrupt other projects).
    if terraform state list 2>/dev/null | grep -q 'aws_ec2_transit_gateway.kong'; then
        local tgw_id
        tgw_id=$(terraform state show 'aws_ec2_transit_gateway.kong' 2>/dev/null | \
            grep '^\s*id\s' | awk '{print $NF}' | tr -d '"' || true)

        if [[ -n "$tgw_id" ]]; then
            local non_deleted_attachments
            non_deleted_attachments=$(aws ec2 describe-transit-gateway-attachments \
                --filters "Name=transit-gateway-id,Values=${tgw_id}" \
                --query 'TransitGatewayAttachments[?State!=`deleted`].TransitGatewayAttachmentId' \
                --output text 2>/dev/null || true)

            # Get our own EKS attachment ID (if still in state)
            local our_attachment=""
            if terraform state list 2>/dev/null | grep -q 'aws_ec2_transit_gateway_vpc_attachment.eks'; then
                our_attachment=$(terraform state show 'aws_ec2_transit_gateway_vpc_attachment.eks' 2>/dev/null | \
                    grep '^\s*id\s' | awk '{print $NF}' | tr -d '"' || true)
            fi

            # Check if there are attachments OTHER than ours
            local has_foreign_attachments=false
            if [[ -n "$non_deleted_attachments" ]]; then
                for att_id in $non_deleted_attachments; do
                    if [[ "$att_id" != "$our_attachment" ]]; then
                        has_foreign_attachments=true
                        break
                    fi
                done
            fi

            if [[ "$has_foreign_attachments" == true ]]; then
                warn "  Transit Gateway ${tgw_id} has attachments from other projects."
                warn "  Removing TGW from terraform state to avoid disrupting other projects."
                terraform state rm aws_ec2_transit_gateway.kong 2>/dev/null || true
                terraform state rm aws_ram_resource_share.kong_tgw 2>/dev/null || true
                terraform state rm aws_ram_resource_association.kong_tgw 2>/dev/null || true
                terraform state rm 'aws_route.kong_cloud_gw[0]' 2>/dev/null || true
                terraform state rm aws_security_group_rule.allow_kong_cloud_gw 2>/dev/null || true
            fi
        fi
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
# Step 5: Delete Kong Cloud Gateway in Konnect
# ---------------------------------------------------------------------------
# Deletion order:
#   1. Remove Data Plane Group config (DP groups must be gone before network)
#   2. Delete the Transit Gateway attachment from the network
#   3. Delete Cloud Gateway network (triggers TGW detach from Kong's AWS account)
#   4. Delete Control Plane
#
# IaC path (preferred): Terraform manages CP, network, and DP group config.
#   Targeted terraform destroy removes them in the correct order.
# Fallback (API path): direct Konnect REST API calls (used if TF state missing).
#
# IMPORTANT: Must run BEFORE the full terraform destroy. Kong Cloud Gateway
# creates a VPC attachment to our Transit Gateway. terraform cannot delete the
# TGW until Kong's attachment is removed — which happens when we delete the
# Konnect network. The wait_for_kong_tgw_detach step then confirms AWS-side
# cleanup before the full terraform destroy runs.
#
# Requires KONNECT_REGION and KONNECT_TOKEN (from .env)
# ---------------------------------------------------------------------------
delete_konnect_resources() {
    log "Step 5: Deleting Kong Cloud Gateway resources in Konnect..."

    local tf_dir="${SCRIPT_DIR}/../terraform"

    # --- IaC path: use terraform destroy -target for managed resources ---
    if [[ -d "${tf_dir}/.terraform" ]]; then
        log "  Terraform state found — removing Konnect resources via terraform destroy -target..."

        local tf_args="-auto-approve"
        if [[ -f "${tf_dir}/terraform.tfvars" ]]; then
            tf_args="-var-file=terraform.tfvars -auto-approve"
        fi

        # Export token so the Konnect provider can authenticate during targeted destroy
        if [[ -n "${KONNECT_TOKEN:-}" ]]; then
            export TF_VAR_konnect_token="${KONNECT_TOKEN}"
        fi

        # Destroy in dependency order: config first (references both CP and network),
        # then network (triggers TGW detachment from Kong's side), then CP.
        cd "$tf_dir"
        terraform destroy -target='konnect_cloud_gateway_configuration.munchgo[0]' $tf_args 2>/dev/null || \
            warn "  Config destroy returned non-zero (may already be gone)"
        terraform destroy -target='konnect_cloud_gateway_network.munchgo[0]' $tf_args 2>/dev/null || \
            warn "  Network destroy returned non-zero (may already be gone)"
        terraform destroy -target='konnect_gateway_control_plane.munchgo[0]' $tf_args 2>/dev/null || \
            warn "  Control plane destroy returned non-zero (may already be gone)"
        cd "$REPO_DIR"

        log "  Konnect resources removed from Terraform state."
        return
    fi

    # --- Fallback: API-based deletion (when no Terraform state) ---
    if [[ -z "${KONNECT_REGION:-}" || -z "${KONNECT_TOKEN:-}" ]]; then
        warn "KONNECT_REGION or KONNECT_TOKEN not set. Skipping Konnect cleanup."
        warn "Delete Cloud Gateway manually: https://cloud.konghq.com → Gateway Manager"
        return
    fi

    local auth_header="Authorization: Bearer ${KONNECT_TOKEN}"

    # --- Find network and delete TGW attachments + network first ---
    log "  Looking up network: ${DCGW_NETWORK_NAME}"
    local networks
    networks=$(curl -s "${KONNECT_GLOBAL_API}/v2/cloud-gateways/networks" -H "$auth_header")
    local network_id
    network_id=$(echo "$networks" | jq -r \
        ".data[] | select(.name == \"${DCGW_NETWORK_NAME}\") | .id" | head -1)

    if [[ -n "$network_id" ]]; then
        # Delete transit gateway attachments first
        log "  Deleting Transit Gateway attachments from network ${network_id}..."
        local tgw_list
        tgw_list=$(curl -s "${KONNECT_GLOBAL_API}/v2/cloud-gateways/networks/${network_id}/transit-gateways" \
            -H "$auth_header")
        local tgw_ids
        tgw_ids=$(echo "$tgw_list" | jq -r '.data[].id // empty' 2>/dev/null || true)

        if [[ -n "$tgw_ids" ]]; then
            echo "$tgw_ids" | while read -r tgw_id; do
                [[ -z "$tgw_id" ]] && continue
                curl -s -X DELETE \
                    "${KONNECT_GLOBAL_API}/v2/cloud-gateways/networks/${network_id}/transit-gateways/${tgw_id}" \
                    -H "$auth_header" >/dev/null 2>&1 || true
                log "  Deleted transit gateway attachment: ${tgw_id}"
            done
        else
            log "  No transit gateway attachments found."
        fi

        # Delete the network (triggers Kong-side TGW detachment)
        log "  Deleting network: ${network_id}"
        local delete_resp
        delete_resp=$(curl -s -w "\n%{http_code}" -X DELETE \
            "${KONNECT_GLOBAL_API}/v2/cloud-gateways/networks/${network_id}" \
            -H "$auth_header")
        local http_code
        http_code=$(echo "$delete_resp" | tail -1)

        if [[ "$http_code" == "204" || "$http_code" == "200" || "$http_code" == "202" ]]; then
            log "  Network deletion initiated."
        else
            warn "  Network deletion returned HTTP ${http_code}."
            warn "  Check: https://cloud.konghq.com → Gateway Manager → Networks"
        fi
    else
        log "  Network '${DCGW_NETWORK_NAME}' not found."
    fi

    # --- Delete control plane (cascades to DP group configs) ---
    log "  Looking up control plane: ${CP_NAME}"
    local cp_list
    cp_list=$(curl -s "${KONNECT_REGIONAL_API}/v2/control-planes?filter%5Bname%5D=${CP_NAME}" \
        -H "$auth_header")
    local cp_id
    cp_id=$(echo "$cp_list" | jq -r '.data[0].id // empty')

    if [[ -n "$cp_id" ]]; then
        log "  Deleting control plane: ${cp_id}..."
        local cp_delete_resp
        cp_delete_resp=$(curl -s -w "\n%{http_code}" -X DELETE \
            "${KONNECT_REGIONAL_API}/v2/control-planes/${cp_id}" \
            -H "$auth_header")
        local cp_http_code
        cp_http_code=$(echo "$cp_delete_resp" | tail -1)

        if [[ "$cp_http_code" == "204" || "$cp_http_code" == "200" ]]; then
            log "  Control plane deleted."
        else
            warn "  Control plane deletion returned HTTP ${cp_http_code}."
        fi
    else
        log "  Control plane '${CP_NAME}' not found."
    fi

    log "  Konnect cleanup complete."
}

# ---------------------------------------------------------------------------
# Step 5b: Clean up ALL leftover Kong Cloud Gateway networks
# ---------------------------------------------------------------------------
# Prevents Konnect network quota exhaustion on next rebuild.
# Queries all networks in the org and deletes any that remain.
cleanup_all_kong_networks() {
    log "Checking for leftover Kong Cloud Gateway networks..."

    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        warn "KONNECT_TOKEN not set — cannot clean up leftover networks"
        return
    fi

    local auth_header="Authorization: Bearer ${KONNECT_TOKEN}"
    local networks
    networks=$(curl -s "${KONNECT_GLOBAL_API}/v2/cloud-gateways/networks" -H "$auth_header" 2>/dev/null || echo '{"data":[]}')

    local network_ids
    network_ids=$(echo "$networks" | jq -r '.data[].id // empty' 2>/dev/null || true)

    if [[ -z "$network_ids" ]]; then
        log "  No leftover networks found."
        return
    fi

    echo "$network_ids" | while read -r net_id; do
        [[ -z "$net_id" ]] && continue
        local net_name
        net_name=$(echo "$networks" | jq -r ".data[] | select(.id == \"$net_id\") | .name" 2>/dev/null || echo "unknown")
        local net_state
        net_state=$(echo "$networks" | jq -r ".data[] | select(.id == \"$net_id\") | .state" 2>/dev/null || echo "unknown")

        log "  Found network: ${net_name} (${net_id}) state=${net_state}"

        # Delete TGW attachments first
        local tgw_list
        tgw_list=$(curl -s "${KONNECT_GLOBAL_API}/v2/cloud-gateways/networks/${net_id}/transit-gateways" \
            -H "$auth_header" 2>/dev/null || echo '{"data":[]}')
        local tgw_ids
        tgw_ids=$(echo "$tgw_list" | jq -r '.data[].id // empty' 2>/dev/null || true)
        if [[ -n "$tgw_ids" ]]; then
            echo "$tgw_ids" | while read -r tgw_id; do
                [[ -z "$tgw_id" ]] && continue
                curl -s -X DELETE \
                    "${KONNECT_GLOBAL_API}/v2/cloud-gateways/networks/${net_id}/transit-gateways/${tgw_id}" \
                    -H "$auth_header" >/dev/null 2>&1 || true
                log "  Deleted TGW attachment: ${tgw_id}"
            done
        fi

        # Delete the network
        curl -s -X DELETE "${KONNECT_GLOBAL_API}/v2/cloud-gateways/networks/${net_id}" \
            -H "$auth_header" >/dev/null 2>&1 || true
        log "  Deleted network: ${net_name}"
    done

    log "  Leftover network cleanup complete."
}

# ---------------------------------------------------------------------------
# Step 9: Reset deployment placeholders for next rebuild
# ---------------------------------------------------------------------------
# After terraform destroy, reset config files back to PLACEHOLDER values
# so the next run of 03-post-terraform-setup.sh can populate them fresh.
reset_deployment_placeholders() {
    log "Step 9: Resetting deployment placeholders for next rebuild..."

    local kong_file="${REPO_DIR}/deck/kong.yaml"
    local cognito_es="${REPO_DIR}/k8s/external-secrets/munchgo-cognito-secret.yaml"
    local db_es="${REPO_DIR}/k8s/external-secrets/munchgo-db-secret.yaml"
    local eso_app="${REPO_DIR}/argocd/apps/09-external-secrets.yaml"
    local insomnia_file="${REPO_DIR}/insomnia/insomnia-env.json"

    # Reset NLB hostname in kong.yaml back to placeholder
    if [[ -f "$kong_file" ]]; then
        # Replace any *.elb.*.amazonaws.com hostname with placeholder
        sed -i.bak -E 's|http://[a-z0-9-]+\.elb\.[a-z0-9-]+\.amazonaws\.com|http://PLACEHOLDER_NLB_DNS|g' "$kong_file"
        # Replace any Cognito issuer URL with placeholder
        sed -i.bak -E 's|https://cognito-idp\.[a-z0-9-]+\.amazonaws\.com/[a-zA-Z0-9_-]+|https://PLACEHOLDER_COGNITO_ISSUER_URL|g' "$kong_file"
        rm -f "${kong_file}.bak"
        log "  Reset deck/kong.yaml placeholders"
    fi

    # Reset external-secrets cognito secret names
    if [[ -f "$cognito_es" ]]; then
        sed -i.bak -E 's|key: kong-gw-poc-munchgo-cognito-[a-z0-9]+|key: PLACEHOLDER-munchgo-cognito|g' "$cognito_es"
        rm -f "${cognito_es}.bak"
        log "  Reset external-secrets/munchgo-cognito-secret.yaml"
    fi

    # Reset external-secrets DB secret names
    if [[ -f "$db_es" ]]; then
        sed -i.bak -E 's|key: kong-gw-poc-munchgo-rds-[a-z0-9]+|key: PLACEHOLDER-munchgo-rds-master|g' "$db_es"
        sed -i.bak -E 's|key: kong-gw-poc-munchgo-auth-db-[a-z0-9]+|key: PLACEHOLDER-munchgo-auth-db|g' "$db_es"
        sed -i.bak -E 's|key: kong-gw-poc-munchgo-consumers-db-[a-z0-9]+|key: PLACEHOLDER-munchgo-consumers-db|g' "$db_es"
        sed -i.bak -E 's|key: kong-gw-poc-munchgo-restaurants-db-[a-z0-9]+|key: PLACEHOLDER-munchgo-restaurants-db|g' "$db_es"
        sed -i.bak -E 's|key: kong-gw-poc-munchgo-couriers-db-[a-z0-9]+|key: PLACEHOLDER-munchgo-couriers-db|g' "$db_es"
        sed -i.bak -E 's|key: kong-gw-poc-munchgo-orders-db-[a-z0-9]+|key: PLACEHOLDER-munchgo-orders-db|g' "$db_es"
        sed -i.bak -E 's|key: kong-gw-poc-munchgo-sagas-db-[a-z0-9]+|key: PLACEHOLDER-munchgo-sagas-db|g' "$db_es"
        rm -f "${db_es}.bak"
        log "  Reset external-secrets/munchgo-db-secret.yaml"
    fi

    # Reset ESO IRSA role ARN
    if [[ -f "$eso_app" ]]; then
        sed -i.bak -E 's|arn:aws:iam::[0-9]+:role/[a-zA-Z0-9_-]+external-secrets[a-zA-Z0-9_-]*|PLACEHOLDER_EXTERNAL_SECRETS_ROLE_ARN|g' "$eso_app"
        rm -f "${eso_app}.bak"
        log "  Reset argocd/apps/09-external-secrets.yaml"
    fi

    # Reset Insomnia environment URL
    if [[ -f "$insomnia_file" ]]; then
        sed -i.bak -E 's|https://[a-z0-9]+\.cloudfront\.net|https://PLACEHOLDER_CLOUDFRONT_URL|g' "$insomnia_file"
        rm -f "${insomnia_file}.bak"
        log "  Reset insomnia/insomnia-env.json"
    fi

    log "  Placeholder reset complete."
}

# ---------------------------------------------------------------------------
# Step 10: Clean up stale .env values
# ---------------------------------------------------------------------------
cleanup_stale_env_values() {
    log "Step 10: Cleaning up stale .env values..."

    if [[ ! -f "$ENV_FILE" ]]; then
        log "  No .env file found — nothing to clean."
        return
    fi

    # Remove stale KONNECT_CP_ID (will be re-populated on next rebuild)
    if grep -q '^KONNECT_CP_ID=' "$ENV_FILE" 2>/dev/null; then
        sed -i.bak '/^KONNECT_CP_ID=/d' "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
        log "  Removed stale KONNECT_CP_ID from .env"
    fi

    log "  .env cleanup complete."
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
    cleanup_all_kong_networks
    wait_for_kong_tgw_detach

    terraform_destroy
    cleanup_cloudfront_cfn_stacks

    # Post-destroy cleanup
    reset_deployment_placeholders
    cleanup_stale_env_values

    echo ""
    log "Full stack teardown complete (EKS + CloudFront + WAF + Konnect)."
    log "Config files reset to placeholders — ready for next rebuild."
    echo ""
}

main "$@"
