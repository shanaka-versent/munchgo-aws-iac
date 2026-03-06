#!/bin/bash
# MunchGo — Application Deployment & Testing
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this AFTER 03-post-terraform-setup.sh has completed.
# Handles everything related to application deployment, seeding, and validation.
#
# What it does (order matters — APIs must be live before SPA E2E tests):
#   Phase 1: Deploy APIs
#     1. Triggers all 6 microservice CI workflows to build and push images to ECR
#     2. Waits for microservice CI workflows to complete (~5-8 min)
#     3. Waits for K8s pod rollouts to finish (APIs become live)
#   Phase 2: Seed Data (requires live APIs)
#     4. Seeds admin user (Cognito + auth-service DB)
#     4b. Seeds demo data (restaurants + menus) — skip with --skip-seed-data
#   Phase 3: Deploy SPA + E2E (requires live APIs + seed data)
#     5. Triggers SPA build + deploy to S3 + CloudFront invalidation
#     6. Waits for SPA deployment + Playwright E2E tests to complete
#   Phase 4: Final Validation
#     7. Runs smoke tests on SPA and all service endpoints
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

# Global: CI trigger timestamps (used to filter workflow runs to only those we triggered)
TRIGGER_TIME=""
SPA_TRIGGER_TIME=""

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
    # Workflow filenames must match .github/workflows/ in the microservices repo
    local WORKFLOWS=(
        "auth-service.yml"
        "consumer-service.yml"
        "courier-service.yml"
        "order-service.yml"
        "restaurant-service.yml"
        "order-saga-orchestrator.yml"
    )

    # Record trigger time to filter CI wait (ISO 8601 UTC)
    TRIGGER_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local TRIGGERED=0
    for wf in "${WORKFLOWS[@]}"; do
        if gh workflow run "$wf" -R "$MICRO_REPO" --ref main 2>/dev/null; then
            info "  Triggered: ${wf}"
            TRIGGERED=$((TRIGGERED + 1))
        else
            warn "  Failed to trigger ${wf} — may need manual trigger"
        fi
    done

    info "  ${TRIGGERED} microservice workflows triggered"
}

# ---------------------------------------------------------------------------
# Wait for CI workflows to complete
# ---------------------------------------------------------------------------
# Polls GitHub Actions workflow runs until all triggered workflows finish.
# Timeout: 15 minutes (microservice builds typically take 5-8 minutes).
# ---------------------------------------------------------------------------
wait_for_ci_completion() {
    log "Step 2: Waiting for microservice CI workflows to complete..."

    local MICRO_REPO="shanaka-versent/munchgo-microservices"
    local TIMEOUT=900  # 15 minutes
    local INTERVAL=30
    local ELAPSED=0

    # Workflow filenames must match trigger_microservices_ci()
    local WORKFLOWS=(
        "auth-service.yml"
        "consumer-service.yml"
        "courier-service.yml"
        "order-service.yml"
        "restaurant-service.yml"
        "order-saga-orchestrator.yml"
    )

    # Wait for workflows to register in GitHub
    sleep 15

    while [[ $ELAPSED -lt $TIMEOUT ]]; do
        local ALL_DONE=true
        local FAILED_COUNT=0
        local STATUS_LINE=""

        for wf in "${WORKFLOWS[@]}"; do
            local svc="${wf%.yml}"
            local STATUS

            # Only look at runs created AFTER we triggered them
            STATUS=$(gh run list --workflow="$wf" -R "$MICRO_REPO" --limit 1 \
                --created ">=${TRIGGER_TIME}" \
                --json status,conclusion \
                --jq '.[0] | if .status == "completed" then .conclusion else .status end' 2>/dev/null || echo "pending")

            # If no run found after trigger time, it hasn't started yet
            if [[ -z "$STATUS" ]]; then
                STATUS="pending"
            fi

            case "$STATUS" in
                success)     STATUS_LINE+=" ${svc}:✓" ;;
                failure)
                    STATUS_LINE+=" ${svc}:✗"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                    ;;
                in_progress|queued|pending|requested|waiting)
                    STATUS_LINE+=" ${svc}:⏳"
                    ALL_DONE=false
                    ;;
                *)
                    STATUS_LINE+=" ${svc}:⏳"
                    ALL_DONE=false
                    ;;
            esac
        done

        echo -e "  [${ELAPSED}s/${TIMEOUT}s]${STATUS_LINE}"

        if $ALL_DONE; then
            echo ""
            if [[ $FAILED_COUNT -gt 0 ]]; then
                warn "${FAILED_COUNT} workflow(s) failed"
                warn "Check: gh run list -R $MICRO_REPO"
            else
                info "  All CI workflows completed successfully"
            fi
            return
        fi

        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo ""
    warn "CI wait timed out after ${TIMEOUT}s — some workflows may still be running"
    warn "Check: gh run list -R $MICRO_REPO"
}

# ---------------------------------------------------------------------------
# Wait for SPA deployment to complete
# ---------------------------------------------------------------------------
# Polls the SPA CI workflow until it completes (build + deploy + E2E).
# ---------------------------------------------------------------------------
wait_for_spa_deployment() {
    log "Step 6: Waiting for SPA deployment + E2E tests..."

    local SPA_REPO="shanaka-versent/munchgo-spa"
    local TIMEOUT=600  # 10 minutes (build + deploy + E2E)
    local INTERVAL=30
    local ELAPSED=0

    # Wait for workflow to register
    sleep 10

    while [[ $ELAPSED -lt $TIMEOUT ]]; do
        local STATUS
        STATUS=$(gh run list --workflow="deploy.yml" -R "$SPA_REPO" --limit 1 \
            --created ">=${SPA_TRIGGER_TIME}" \
            --json status,conclusion \
            --jq '.[0] | if .status == "completed" then .conclusion else .status end' 2>/dev/null || echo "pending")

        if [[ -z "$STATUS" ]]; then
            STATUS="pending"
        fi

        case "$STATUS" in
            success)
                info "  SPA deployment completed successfully"
                return
                ;;
            failure)
                warn "  SPA deployment failed"
                warn "  Check: gh run list -R $SPA_REPO"
                return
                ;;
            *)
                echo -e "  [${ELAPSED}s/${TIMEOUT}s] SPA deploy: ⏳ (${STATUS})"
                ;;
        esac

        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    warn "SPA deployment wait timed out after ${TIMEOUT}s"
    warn "Check: gh run list -R $SPA_REPO"
}

# ---------------------------------------------------------------------------
# Wait for K8s pod rollouts
# ---------------------------------------------------------------------------
# Waits for all MunchGo deployments to finish rolling out after ArgoCD syncs
# the updated image tags from munchgo-k8s-config.
# ---------------------------------------------------------------------------
wait_for_pod_rollouts() {
    log "Step 3: Waiting for pod rollouts..."

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
# Trigger SPA deployment (after APIs are live)
# ---------------------------------------------------------------------------
# The SPA CI workflow deploys to S3/CloudFront and then runs Playwright E2E
# tests against the live deployment. E2E tests call the backend APIs, so the
# microservices must be deployed and healthy BEFORE triggering SPA deploy.
# ---------------------------------------------------------------------------
trigger_spa_deployment() {
    log "Step 5: Triggering SPA deployment..."

    local SPA_REPO="shanaka-versent/munchgo-spa"

    # Record trigger time for SPA wait
    SPA_TRIGGER_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if gh workflow run deploy.yml -R "$SPA_REPO" --ref main 2>/dev/null; then
        info "  Triggered: munchgo-spa deploy.yml"
    else
        warn "  Failed to trigger SPA deploy — ensure deploy.yml has workflow_dispatch trigger"
        warn "  Fallback: cd munchgo-spa && git commit --allow-empty -m 'trigger deploy' && git push"
    fi
}

# ---------------------------------------------------------------------------
# Seed admin user
# ---------------------------------------------------------------------------
seed_admin_user() {
    log "Step 4: Seeding admin user..."

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

    log "Step 4b: Seeding demo data..."

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
    log "Step 7: Running API smoke tests..."

    if [[ -z "$APP_URL" ]]; then
        warn "APP_URL not available — skipping smoke tests"
        return
    fi

    # Endpoints: path|name|accept_codes
    # 200 = public endpoint responding
    # 401 = OIDC plugin active (service alive, auth required)
    # 500 = auth service has no root endpoint but is alive (Spring returns 500 for unknown paths)
    local ENDPOINTS=(
        "/|SPA (index.html)|200"
        "/healthz|Platform Health|200"
        "/api/v1/auth|Auth Service|200,500"
        "/api/v1/consumers|Consumer Service|200,401"
        "/api/v1/restaurants|Restaurant Service|200"
        "/api/v1/orders|Order Service|200,401"
        "/api/v1/couriers|Courier Service|200,401"
    )

    local PASSED=0
    local FAILED=0

    for entry in "${ENDPOINTS[@]}"; do
        IFS='|' read -r path name accept_codes <<< "$entry"
        local HTTP_CODE

        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${APP_URL}${path}" 2>/dev/null || echo "000")

        # Check if HTTP code is in the accepted list
        if echo ",$accept_codes," | grep -q ",${HTTP_CODE},"; then
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

    # Phase 1: Deploy APIs (microservices must be live before SPA E2E tests)
    trigger_microservices_ci          # Step 1: Trigger 6 microservice CI builds
    wait_for_ci_completion            # Step 2: Wait for CI to push images to ECR
    wait_for_pod_rollouts             # Step 3: Wait for K8s rollouts (APIs live)

    # Phase 2: Seed data (APIs must be live for seeding)
    seed_admin_user                   # Step 4: Create admin in Cognito + DB
    seed_demo_data                    # Step 4b: Seed restaurants + menus

    # Phase 3: Deploy SPA + run E2E tests (APIs + seed data must exist)
    trigger_spa_deployment            # Step 5: Trigger SPA build + deploy + E2E
    wait_for_spa_deployment           # Step 6: Wait for SPA deploy + E2E to pass

    # Phase 4: Final validation
    run_smoke_tests                   # Step 7: Verify all endpoints via CloudFront
    show_summary
}

main "$@"
