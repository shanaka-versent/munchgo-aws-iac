#!/bin/bash
# MunchGo — Application Deployment & Testing
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this AFTER 03-post-terraform-setup.sh has completed.
# Handles everything related to application deployment, seeding, and validation.
#
# What it does:
#   1. Triggers all 6 microservice CI workflows to build and push images to ECR
#   2. Triggers SPA build + deploy to S3 + CloudFront invalidation
#   3. Waits for CI workflows to complete (~5-8 min)
#   4. Waits for K8s pod rollouts to finish
#   5. Seeds admin user (Cognito + auth-service DB)
#   6. Seeds demo data (restaurants + menus) — skip with --skip-seed-data
#   7. Runs smoke tests on all service health endpoints
#
# Prerequisites:
#   - 03-post-terraform-setup.sh completed (infra configured)
#   - gh CLI installed and authenticated (brew install gh && gh auth login)
#   - kubectl configured for the EKS cluster
#
# Usage:
#   ./scripts/04-deploy-apps.sh                # Full deploy + seed + test
#   ./scripts/04-deploy-apps.sh --skip-seed-data  # Skip demo data seeding

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

# Auto-source .env if it exists
ENV_FILE="${REPO_DIR}/.env"
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
info() { echo -e "${CYAN}[DEPLOY]${NC} $*"; }

# Parse arguments
SKIP_SEED_DATA=false
for arg in "$@"; do
    case "$arg" in
        --skip-seed-data) SKIP_SEED_DATA=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Read Terraform outputs (APP_URL etc.)
# ---------------------------------------------------------------------------
read_terraform_outputs() {
    log "Reading Terraform outputs..."
    cd "$TERRAFORM_DIR"
    APP_URL=$(terraform output -raw application_url 2>/dev/null || echo "")
    cd "$REPO_DIR"

    if [[ -n "$APP_URL" ]]; then
        info "  Application URL: ${APP_URL}"
    else
        warn "  CloudFront URL not available"
    fi
}

# ---------------------------------------------------------------------------
# Trigger microservices CI to push images to ECR
# ---------------------------------------------------------------------------
# After a rebuild, ECR repos are empty (force_delete on destroy). This
# triggers all 6 microservice CI workflows to build and push images.
# The CI pipeline: build → push GHCR → sync ECR → update gitops → trigger tests
# ---------------------------------------------------------------------------
trigger_microservices_ci() {
    if ! command -v gh &>/dev/null; then
        error "gh CLI not found — cannot trigger CI workflows"
        error "Install with: brew install gh"
        return 1
    fi

    if ! gh auth status &>/dev/null; then
        error "gh CLI not authenticated — run: gh auth login"
        return 1
    fi

    log "Step 1: Triggering microservices CI workflows..."

    local MICRO_REPO="shanaka-versent/munchgo-microservices"
    local SERVICES=(
        "auth-service"
        "consumer-service"
        "courier-service"
        "order-service"
        "restaurant-service"
        "saga-orchestrator"
    )

    local TRIGGERED=0
    for svc in "${SERVICES[@]}"; do
        if gh workflow run "${svc}.yml" -R "$MICRO_REPO" --ref main 2>/dev/null; then
            info "  Triggered: ${svc}.yml"
            TRIGGERED=$((TRIGGERED + 1))
        else
            warn "  Failed to trigger ${svc}.yml — may need manual trigger"
        fi
    done

    log "Step 2: Triggering SPA deployment..."
    local SPA_REPO="shanaka-versent/munchgo-spa"
    if gh workflow run deploy.yml -R "$SPA_REPO" --ref main 2>/dev/null; then
        info "  Triggered: munchgo-spa deploy.yml"
        TRIGGERED=$((TRIGGERED + 1))
    else
        warn "  Failed to trigger SPA deploy — may need manual trigger"
    fi

    info "  ${TRIGGERED} workflows triggered"
}

# ---------------------------------------------------------------------------
# Wait for CI workflows to complete
# ---------------------------------------------------------------------------
# Polls GitHub Actions workflow runs until all triggered workflows finish.
# Timeout: 15 minutes (microservice builds typically take 5-8 minutes).
# ---------------------------------------------------------------------------
wait_for_ci_completion() {
    log "Step 3: Waiting for CI workflows to complete..."

    local MICRO_REPO="shanaka-versent/munchgo-microservices"
    local SPA_REPO="shanaka-versent/munchgo-spa"
    local TIMEOUT=900  # 15 minutes
    local INTERVAL=30
    local ELAPSED=0

    local SERVICES=(
        "auth-service"
        "consumer-service"
        "courier-service"
        "order-service"
        "restaurant-service"
        "saga-orchestrator"
    )

    # Wait a few seconds for workflows to register
    sleep 10

    while [[ $ELAPSED -lt $TIMEOUT ]]; do
        local ALL_DONE=true
        local STATUS_LINE=""

        # Check microservices workflows
        for svc in "${SERVICES[@]}"; do
            local STATUS
            STATUS=$(gh run list --workflow="${svc}.yml" -R "$MICRO_REPO" --limit 1 \
                --json status,conclusion --jq '.[0] | if .status == "completed" then .conclusion else .status end' 2>/dev/null || echo "unknown")

            case "$STATUS" in
                success)     STATUS_LINE+=" ${svc}:✓" ;;
                failure)
                    error "  ${svc} CI FAILED"
                    error "  Check: gh run list --workflow=${svc}.yml -R $MICRO_REPO --limit 1"
                    STATUS_LINE+=" ${svc}:✗"
                    ;;
                in_progress) STATUS_LINE+=" ${svc}:⏳"; ALL_DONE=false ;;
                queued)      STATUS_LINE+=" ${svc}:⏳"; ALL_DONE=false ;;
                *)           STATUS_LINE+=" ${svc}:?"; ALL_DONE=false ;;
            esac
        done

        # Check SPA workflow
        local SPA_STATUS
        SPA_STATUS=$(gh run list --workflow="deploy.yml" -R "$SPA_REPO" --limit 1 \
            --json status,conclusion --jq '.[0] | if .status == "completed" then .conclusion else .status end' 2>/dev/null || echo "unknown")

        case "$SPA_STATUS" in
            success)     STATUS_LINE+=" spa:✓" ;;
            failure)     STATUS_LINE+=" spa:✗"; error "  SPA deploy FAILED" ;;
            in_progress) STATUS_LINE+=" spa:⏳"; ALL_DONE=false ;;
            queued)      STATUS_LINE+=" spa:⏳"; ALL_DONE=false ;;
            *)           STATUS_LINE+=" spa:?"; ALL_DONE=false ;;
        esac

        echo -e "\r  [${ELAPSED}s/${TIMEOUT}s]${STATUS_LINE}"

        if $ALL_DONE; then
            echo ""
            info "  All CI workflows completed"
            return
        fi

        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo ""
    warn "CI wait timed out after ${TIMEOUT}s — some workflows may still be running"
    warn "Check: gh run list -R $MICRO_REPO && gh run list -R $SPA_REPO"
}

# ---------------------------------------------------------------------------
# Wait for K8s pod rollouts
# ---------------------------------------------------------------------------
# Waits for all MunchGo deployments to finish rolling out after ArgoCD syncs
# the updated image tags from munchgo-k8s-config.
# ---------------------------------------------------------------------------
wait_for_pod_rollouts() {
    log "Step 4: Waiting for pod rollouts..."

    local SERVICES=(
        "auth-service"
        "consumer-service"
        "courier-service"
        "order-service"
        "restaurant-service"
        "saga-orchestrator"
    )

    local FAILED=0
    for svc in "${SERVICES[@]}"; do
        if kubectl get deployment "$svc" -n munchgo &>/dev/null; then
            if kubectl rollout status deployment/"$svc" -n munchgo --timeout=300s 2>/dev/null; then
                info "  ${svc}: rolled out"
            else
                warn "  ${svc}: rollout timeout"
                FAILED=$((FAILED + 1))
            fi
        else
            warn "  ${svc}: deployment not found (ArgoCD may not have synced yet)"
            FAILED=$((FAILED + 1))
        fi
    done

    if [[ $FAILED -gt 0 ]]; then
        warn "${FAILED} service(s) did not roll out — ArgoCD sync may be pending"
        warn "Check: kubectl get pods -n munchgo"
        warn "ArgoCD may need up to 3 minutes to detect gitops changes"
    fi
}

# ---------------------------------------------------------------------------
# Seed admin user
# ---------------------------------------------------------------------------
seed_admin_user() {
    log "Step 5: Seeding admin user..."

    local SEED_SCRIPT="${SCRIPT_DIR}/seed-admin-user.sh"
    if [[ -f "$SEED_SCRIPT" ]]; then
        bash "$SEED_SCRIPT" || warn "Admin seed failed — run manually: ./scripts/seed-admin-user.sh"
    else
        warn "Admin seed script not found: $SEED_SCRIPT"
    fi
}

# ---------------------------------------------------------------------------
# Seed demo data (restaurants + menus)
# ---------------------------------------------------------------------------
seed_demo_data() {
    if $SKIP_SEED_DATA; then
        info "  Skipping demo data seed (--skip-seed-data)"
        return
    fi

    log "Step 6: Seeding demo data..."

    local SEED_SCRIPT="${SCRIPT_DIR}/seed-demo-data.sh"
    if [[ -f "$SEED_SCRIPT" ]]; then
        bash "$SEED_SCRIPT" || warn "Demo data seed failed — run manually: ./scripts/seed-demo-data.sh"
    else
        warn "Demo data seed script not found: $SEED_SCRIPT"
    fi
}

# ---------------------------------------------------------------------------
# Smoke tests — verify all service health endpoints via CloudFront
# ---------------------------------------------------------------------------
run_smoke_tests() {
    log "Step 7: Running smoke tests..."

    if [[ -z "$APP_URL" ]]; then
        warn "APP_URL not available — skipping smoke tests"
        return
    fi

    local ENDPOINTS=(
        "/healthz|Platform Health"
        "/api/v1/auth/health|Auth Service"
        "/api/v1/consumers/health|Consumer Service"
        "/api/v1/restaurants/health|Restaurant Service"
        "/api/v1/orders/health|Order Service"
        "/api/v1/couriers/health|Courier Service"
    )

    local PASSED=0
    local FAILED=0

    for entry in "${ENDPOINTS[@]}"; do
        local path="${entry%%|*}"
        local name="${entry##*|}"
        local HTTP_CODE

        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${APP_URL}${path}" 2>/dev/null || echo "000")

        if [[ "$HTTP_CODE" == "200" ]]; then
            info "  ✓ ${name} (${path}) — HTTP ${HTTP_CODE}"
            PASSED=$((PASSED + 1))
        else
            warn "  ✗ ${name} (${path}) — HTTP ${HTTP_CODE}"
            FAILED=$((FAILED + 1))
        fi
    done

    echo ""
    if [[ $FAILED -eq 0 ]]; then
        info "  All ${PASSED} smoke tests passed"
    else
        warn "  ${PASSED} passed, ${FAILED} failed"
        warn "  Failed endpoints may need more time for pods to become ready"
        warn "  Re-run smoke tests: curl ${APP_URL}/healthz"
    fi
}

# ---------------------------------------------------------------------------
# Show summary
# ---------------------------------------------------------------------------
show_summary() {
    echo ""
    echo "=========================================="
    echo "  Application Deployment Complete"
    echo "=========================================="
    echo ""
    if [[ -n "$APP_URL" ]]; then
        echo "  Application URL: ${APP_URL}"
        echo ""
        echo "  Test endpoints:"
        echo "    curl ${APP_URL}/healthz"
        echo "    curl ${APP_URL}/api/v1/restaurants"
        echo ""
    fi
    echo "  Useful commands:"
    echo "    kubectl get pods -n munchgo             # Check pod status"
    echo "    ./scripts/02-generate-jwt.sh            # Generate test JWT token"
    echo "    ./scripts/seed-demo-data.sh             # Re-seed demo data"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  MunchGo — Application Deployment & Testing"
    echo "=============================================="
    echo ""

    read_terraform_outputs
    trigger_microservices_ci
    wait_for_ci_completion
    wait_for_pod_rollouts
    seed_admin_user
    seed_demo_data
    run_smoke_tests
    show_summary
}

main "$@"
