#!/bin/bash
# Kong Cloud Gateway on EKS - Post-Terraform Setup
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this script AFTER 'terraform apply' AND after ArgoCD has synced
# (Istio Gateway created the internal NLB).
#
# What it does:
#   1. Reads Terraform outputs (VPC, TGW, Cognito, RDS secrets)
#   2. Waits for the Istio Gateway NLB to be provisioned
#   3. Auto-populates ALL placeholders in kong.yaml, ExternalSecrets, and K8s overlays
#   4. Shows the deck gateway sync command and access URL
#
# Usage:
#   ./scripts/03-post-terraform-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

# K8s config repo (relative to infra repo)
K8S_CONFIG_REPO="${REPO_DIR}/../../Modernisation/Java-demo/munchgo-k8s-config"

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
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${CYAN}[CONFIG]${NC} $*"; }

# ---------------------------------------------------------------------------
# Read all Terraform outputs
# ---------------------------------------------------------------------------
read_terraform_outputs() {
    log "Reading Terraform outputs..."

    cd "$TERRAFORM_DIR"

    VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "N/A")
    VPC_CIDR=$(terraform output -raw vpc_cidr 2>/dev/null || echo "N/A")
    TRANSIT_GW_ID=$(terraform output -raw transit_gateway_id 2>/dev/null || echo "N/A")
    RAM_SHARE_ARN=$(terraform output -raw ram_share_arn 2>/dev/null || echo "N/A")
    NAME_PREFIX=$(terraform output -raw name_prefix 2>/dev/null || echo "N/A")

    # Cognito outputs
    COGNITO_ISSUER_URL=$(terraform output -raw cognito_issuer_url 2>/dev/null || echo "")
    COGNITO_SECRET_NAME=$(terraform output -raw cognito_secret_name 2>/dev/null || echo "")
    COGNITO_AUTH_ROLE_ARN=$(terraform output -raw cognito_auth_service_role_arn 2>/dev/null || echo "")

    # RDS secret names
    RDS_MASTER_SECRET=$(terraform output -raw rds_master_secret_name 2>/dev/null || echo "")
    RDS_AUTH_SECRET=$(terraform output -raw rds_auth_db_secret_name 2>/dev/null || echo "")
    RDS_CONSUMERS_SECRET=$(terraform output -raw rds_consumers_db_secret_name 2>/dev/null || echo "")
    RDS_RESTAURANTS_SECRET=$(terraform output -raw rds_restaurants_db_secret_name 2>/dev/null || echo "")
    RDS_COURIERS_SECRET=$(terraform output -raw rds_couriers_db_secret_name 2>/dev/null || echo "")
    RDS_ORDERS_SECRET=$(terraform output -raw rds_orders_db_secret_name 2>/dev/null || echo "")
    RDS_SAGAS_SECRET=$(terraform output -raw rds_sagas_db_secret_name 2>/dev/null || echo "")

    # MSK (Kafka) bootstrap brokers
    MSK_BOOTSTRAP_BROKERS=$(terraform output -raw msk_bootstrap_brokers 2>/dev/null || echo "")

    # External Secrets IRSA
    EXTERNAL_SECRETS_ROLE_ARN=$(terraform output -raw external_secrets_role_arn 2>/dev/null || echo "")

    # AWS Account ID (extracted from ECR repository URL)
    AWS_ACCOUNT_ID=$(terraform output -json ecr_repository_urls 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d.values())[0].split('.')[0])" 2>/dev/null || echo "")

    # CloudFront URL
    APP_URL=$(terraform output -raw application_url 2>/dev/null || echo "")

    cd "$REPO_DIR"

    echo ""
    log "Infrastructure:"
    echo "  VPC:           $VPC_ID ($VPC_CIDR)"
    echo "  Transit GW:    $TRANSIT_GW_ID"
    echo "  Name Prefix:   $NAME_PREFIX"
    echo ""
    log "Cognito:"
    echo "  Issuer URL:    $COGNITO_ISSUER_URL"
    echo "  Secret Name:   $COGNITO_SECRET_NAME"
    echo "  Auth Role ARN: $COGNITO_AUTH_ROLE_ARN"
    echo ""
    if [[ -n "$APP_URL" ]]; then
        log "Application URL: $APP_URL"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Get Istio Gateway NLB endpoint
# ---------------------------------------------------------------------------
get_gateway_endpoint() {
    log "Fetching Istio Gateway NLB endpoint..."

    for i in {1..30}; do
        GATEWAY_STATUS=$(kubectl get gateway -n istio-ingress kong-cloud-gw-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null) || true
        if [ "$GATEWAY_STATUS" = "True" ]; then
            log "Gateway is ready"
            break
        fi
        if [ $i -eq 30 ]; then
            warn "Timeout waiting for Gateway. It may still be provisioning."
            warn "Check: kubectl get gateway -n istio-ingress"
            NLB_HOSTNAME="PENDING"
            return
        fi
        echo -n "."
        sleep 10
    done

    NLB_HOSTNAME=$(kubectl get gateway -n istio-ingress kong-cloud-gw-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "PENDING")
    log "NLB Endpoint: ${NLB_HOSTNAME}"
}

# ---------------------------------------------------------------------------
# Populate kong.yaml placeholders
# ---------------------------------------------------------------------------
populate_kong_yaml() {
    local KONG_FILE="${REPO_DIR}/deck/kong.yaml"

    if [[ ! -f "$KONG_FILE" ]]; then
        warn "deck/kong.yaml not found, skipping"
        return
    fi

    log "Populating deck/kong.yaml placeholders..."

    if [[ "$NLB_HOSTNAME" != "PENDING" ]]; then
        sed -i.bak "s|PLACEHOLDER_NLB_DNS|${NLB_HOSTNAME}|g" "$KONG_FILE"
        info "  Replaced PLACEHOLDER_NLB_DNS → ${NLB_HOSTNAME}"
    else
        warn "  NLB not ready — PLACEHOLDER_NLB_DNS not replaced"
    fi

    if [[ -n "$COGNITO_ISSUER_URL" ]]; then
        sed -i.bak "s|PLACEHOLDER_COGNITO_ISSUER_URL|${COGNITO_ISSUER_URL}|g" "$KONG_FILE"
        info "  Replaced PLACEHOLDER_COGNITO_ISSUER_URL → ${COGNITO_ISSUER_URL}"
    else
        warn "  Cognito not enabled — PLACEHOLDER_COGNITO_ISSUER_URL not replaced"
    fi

    rm -f "${KONG_FILE}.bak"
}

# ---------------------------------------------------------------------------
# Populate ExternalSecret placeholders
# ---------------------------------------------------------------------------
populate_external_secrets() {
    log "Populating ExternalSecret placeholders..."

    # Cognito ExternalSecret
    local COGNITO_ES="${REPO_DIR}/k8s/external-secrets/munchgo-cognito-secret.yaml"
    if [[ -f "$COGNITO_ES" && -n "$COGNITO_SECRET_NAME" ]]; then
        sed -i.bak "s|PLACEHOLDER-munchgo-cognito|${COGNITO_SECRET_NAME}|g" "$COGNITO_ES"
        info "  Cognito secret: ${COGNITO_SECRET_NAME}"
        rm -f "${COGNITO_ES}.bak"
    fi

    # DB ExternalSecrets
    local DB_ES="${REPO_DIR}/k8s/external-secrets/munchgo-db-secret.yaml"
    if [[ -f "$DB_ES" ]]; then
        [[ -n "$RDS_MASTER_SECRET" ]] && sed -i.bak "s|PLACEHOLDER-munchgo-rds-master|${RDS_MASTER_SECRET}|g" "$DB_ES"
        [[ -n "$RDS_AUTH_SECRET" ]] && sed -i.bak "s|PLACEHOLDER-munchgo-auth-db|${RDS_AUTH_SECRET}|g" "$DB_ES"
        [[ -n "$RDS_CONSUMERS_SECRET" ]] && sed -i.bak "s|PLACEHOLDER-munchgo-consumers-db|${RDS_CONSUMERS_SECRET}|g" "$DB_ES"
        [[ -n "$RDS_RESTAURANTS_SECRET" ]] && sed -i.bak "s|PLACEHOLDER-munchgo-restaurants-db|${RDS_RESTAURANTS_SECRET}|g" "$DB_ES"
        [[ -n "$RDS_COURIERS_SECRET" ]] && sed -i.bak "s|PLACEHOLDER-munchgo-couriers-db|${RDS_COURIERS_SECRET}|g" "$DB_ES"
        [[ -n "$RDS_ORDERS_SECRET" ]] && sed -i.bak "s|PLACEHOLDER-munchgo-orders-db|${RDS_ORDERS_SECRET}|g" "$DB_ES"
        [[ -n "$RDS_SAGAS_SECRET" ]] && sed -i.bak "s|PLACEHOLDER-munchgo-sagas-db|${RDS_SAGAS_SECRET}|g" "$DB_ES"
        info "  DB secrets populated"
        rm -f "${DB_ES}.bak"
    fi
}

# ---------------------------------------------------------------------------
# Populate External Secrets Operator IRSA role ARN
# ---------------------------------------------------------------------------
populate_eso_irsa() {
    local ESO_APP="${REPO_DIR}/argocd/apps/09-external-secrets.yaml"
    if [[ -f "$ESO_APP" && -n "$EXTERNAL_SECRETS_ROLE_ARN" ]]; then
        log "Populating External Secrets IRSA role ARN..."
        sed -i.bak "s|PLACEHOLDER_EXTERNAL_SECRETS_ROLE_ARN|${EXTERNAL_SECRETS_ROLE_ARN}|g" "$ESO_APP"
        info "  ESO IRSA → ${EXTERNAL_SECRETS_ROLE_ARN}"
        rm -f "${ESO_APP}.bak"
    fi
}

# ---------------------------------------------------------------------------
# Populate K8s config overlay (IRSA role ARN)
# ---------------------------------------------------------------------------
populate_k8s_overlay() {
    if [[ ! -d "$K8S_CONFIG_REPO" ]]; then
        warn "munchgo-k8s-config repo not found at ${K8S_CONFIG_REPO}, skipping overlay patches"
        return
    fi

    log "Populating munchgo-k8s-config overlays..."

    # Replace ACCOUNT_ID placeholder with actual AWS account ID in all dev overlays
    if [[ -n "$AWS_ACCOUNT_ID" ]]; then
        find "${K8S_CONFIG_REPO}/overlays/dev" -name 'kustomization.yaml' -exec \
            sed -i.bak "s|ACCOUNT_ID|${AWS_ACCOUNT_ID}|g" {} +
        find "${K8S_CONFIG_REPO}/overlays/dev" -name '*.bak' -delete
        info "  ECR account ID → ${AWS_ACCOUNT_ID}"
    fi

    # Replace Cognito IRSA role ARN in auth-service overlay
    local AUTH_OVERLAY="${K8S_CONFIG_REPO}/overlays/dev/auth-service/kustomization.yaml"
    if [[ -f "$AUTH_OVERLAY" && -n "$COGNITO_AUTH_ROLE_ARN" ]]; then
        sed -i.bak "s|COGNITO_AUTH_SERVICE_ROLE_ARN|${COGNITO_AUTH_ROLE_ARN}|g" "$AUTH_OVERLAY"
        info "  auth-service IRSA → ${COGNITO_AUTH_ROLE_ARN}"
        rm -f "${AUTH_OVERLAY}.bak"
    fi
}

# ---------------------------------------------------------------------------
# Create Kafka config secret from MSK bootstrap brokers
# ---------------------------------------------------------------------------
create_kafka_secret() {
    if [[ -z "$MSK_BOOTSTRAP_BROKERS" ]]; then
        warn "MSK bootstrap brokers not available — skipping Kafka secret"
        return
    fi

    log "Creating munchgo-kafka-config secret..."
    kubectl create secret generic munchgo-kafka-config \
        --from-literal=bootstrap_brokers="${MSK_BOOTSTRAP_BROKERS}" \
        -n munchgo --dry-run=client -o yaml | kubectl apply -f -
    info "  Kafka bootstrap brokers configured"
}

# ---------------------------------------------------------------------------
# Create service databases on RDS
# ---------------------------------------------------------------------------
create_service_databases() {
    log "Creating service databases on RDS..."

    # Wait for ExternalSecrets to sync the DB credentials (up to 5 minutes)
    local MAX_WAIT=300
    local INTERVAL=10
    local ELAPSED=0

    if ! kubectl get secret munchgo-db-master -n munchgo &>/dev/null; then
        log "Waiting for munchgo-db-master secret (ExternalSecrets sync)..."
        while [[ $ELAPSED -lt $MAX_WAIT ]]; do
            if kubectl get secret munchgo-db-master -n munchgo &>/dev/null; then
                info "munchgo-db-master secret is ready (waited ${ELAPSED}s)"
                break
            fi
            sleep "$INTERVAL"
            ELAPSED=$((ELAPSED + INTERVAL))
            echo -ne "\r  Waiting... ${ELAPSED}s / ${MAX_WAIT}s"
        done
        echo ""

        if ! kubectl get secret munchgo-db-master -n munchgo &>/dev/null; then
            warn "munchgo-db-master secret not found after ${MAX_WAIT}s — skipping DB creation"
            warn "Run manually after ExternalSecrets syncs: ./scripts/03-post-terraform-setup.sh"
            return
        fi
    fi

    kubectl delete job db-init -n munchgo 2>/dev/null || true

    cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: db-init
  namespace: munchgo
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      containers:
        - name: psql
          image: postgres:15-alpine
          env:
            - name: PGHOST
              valueFrom:
                secretKeyRef:
                  name: munchgo-db-master
                  key: host
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: munchgo-db-master
                  key: username
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: munchgo-db-master
                  key: password
            - name: PGDATABASE
              value: munchgo
          command: ["sh", "-c"]
          args:
            - |
              for db in auth consumers restaurants couriers orders sagas; do
                psql -c "CREATE DATABASE $db;" 2>/dev/null && echo "Created: $db" || echo "Exists: $db"
              done
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
  backoffLimit: 1
EOF

    # Wait for job to complete
    kubectl wait --for=condition=complete job/db-init -n munchgo --timeout=120s 2>/dev/null || \
        warn "DB init job did not complete in time — check: kubectl logs job/db-init -n munchgo"

    info "  Service databases created"
}

# ---------------------------------------------------------------------------
# Seed default admin user
# ---------------------------------------------------------------------------
seed_admin_user() {
    local SEED_SCRIPT="${SCRIPT_DIR}/04-seed-admin-user.sh"
    if [[ -f "$SEED_SCRIPT" ]]; then
        log "Seeding default admin user..."
        bash "$SEED_SCRIPT" || warn "Admin seed script failed — run manually: ./scripts/04-seed-admin-user.sh"
    else
        warn "Admin seed script not found: $SEED_SCRIPT"
    fi
}

# ---------------------------------------------------------------------------
# Show next steps
# ---------------------------------------------------------------------------
show_next_steps() {
    echo ""
    echo "=========================================="
    echo "  Next Steps"
    echo "=========================================="
    echo ""
    echo "  1. Sync Kong configuration:"
    echo "     deck gateway sync deck/kong.yaml \\"
    echo "       --konnect-addr https://\${KONNECT_REGION}.api.konghq.com \\"
    echo "       --konnect-token \$KONNECT_TOKEN \\"
    echo "       --konnect-control-plane-name \$KONNECT_CONTROL_PLANE_NAME"
    echo ""
    echo "  2. Commit the populated config files:"
    echo "     git add deck/kong.yaml k8s/external-secrets/"
    echo "     git commit -m 'Populate deployment placeholders from terraform outputs'"
    echo ""
    echo "  3. Generate a test token:"
    echo "     ./scripts/02-generate-jwt.sh"
    echo ""
    echo "  4. Test the API:"
    if [[ -n "$APP_URL" ]]; then
        echo "     curl ${APP_URL}/healthz"
        echo "     curl ${APP_URL}/api/auth/health"
        echo "     curl -H 'Authorization: Bearer \$ACCESS_TOKEN' ${APP_URL}/api/orders"
    else
        echo "     curl \$APP_URL/healthz"
        echo "     (Deploy CloudFront in Step 7 to get the application URL)"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Post-Terraform Setup — Kong Cloud Gateway"
    echo "  Placeholder Auto-Population"
    echo "=============================================="
    echo ""

    read_terraform_outputs
    get_gateway_endpoint
    populate_kong_yaml
    populate_external_secrets
    populate_eso_irsa
    populate_k8s_overlay
    create_service_databases
    create_kafka_secret
    seed_admin_user
    show_next_steps
}

main "$@"
