#!/bin/bash
# Kong Cloud Gateway on EKS - Post-Terraform Setup
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this script AFTER 'terraform apply' AND after ArgoCD has synced
# (Istio Gateway created the internal NLB).
#
# Scope: Infrastructure configuration ONLY (idempotent, safe to re-run).
# Application deployment (CI triggers, seeding, testing) is handled by
# 04-deploy-apps.sh — run that script after this one completes.
#
# What it does:
#   1. Reads Terraform outputs (VPC, TGW, Cognito, RDS secrets)
#   2. Auto-discovers Kong proxy domain and updates CloudFront origin
#   3. Configures ArgoCD credentials and verifies VPC routes
#   4. Waits for the Istio Gateway NLB to be provisioned
#   5. Auto-populates ALL placeholders in kong.yaml, ExternalSecrets, and K8s overlays
#   6. Creates service databases and Kafka secret (infra prerequisites)
#   7. Syncs Kong routes to Konnect via decK (requires KONNECT_TOKEN in .env)
#   8. Updates GitHub CI/CD variables for downstream workflows
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

# Konnect API base URLs (derived from KONNECT_REGION)
KONNECT_GLOBAL_API="https://global.api.konghq.com"
KONNECT_REGIONAL_API="https://${KONNECT_REGION:-au}.api.konghq.com"

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
# Generate TLS certificates for Istio Gateway HTTPS listener
# ---------------------------------------------------------------------------
# Creates a self-signed CA + server certificate and the K8s TLS secret
# referenced by the Gateway HTTPS listener (port 443).
# Without this secret, the NLB port 443 target is unhealthy and
# CloudFront → Kong traffic fails.
# ---------------------------------------------------------------------------
generate_gateway_tls() {
    log "Generating TLS certificates for Istio Gateway..."

    local CERT_SCRIPT="${SCRIPT_DIR}/01-generate-certs.sh"
    if [[ ! -f "$CERT_SCRIPT" ]]; then
        warn "Certificate script not found: $CERT_SCRIPT"
        return
    fi

    # Check if secret already exists
    if kubectl get secret istio-gateway-tls -n istio-ingress &>/dev/null; then
        info "  TLS secret 'istio-gateway-tls' already exists — skipping"
        return
    fi

    bash "$CERT_SCRIPT" || warn "TLS cert generation failed — run manually: ./scripts/01-generate-certs.sh"
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
# Sync Kong decK configuration to Konnect
# ---------------------------------------------------------------------------
sync_kong_config() {
    local KONG_FILE="${REPO_DIR}/deck/kong.yaml"

    if [[ ! -f "$KONG_FILE" ]]; then
        warn "deck/kong.yaml not found — skipping Kong sync"
        return
    fi

    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        warn "KONNECT_TOKEN not set — skipping Kong sync"
        warn "Set KONNECT_TOKEN in .env and re-run, or sync manually:"
        warn "  deck gateway sync deck/kong.yaml --konnect-addr \${KONNECT_REGIONAL_API} --konnect-token \$KONNECT_TOKEN --konnect-control-plane-name \$KONNECT_CONTROL_PLANE_NAME"
        return
    fi

    local CP_NAME="${KONNECT_CONTROL_PLANE_NAME:-MunchGo}"

    log "Syncing Kong configuration to Konnect (${CP_NAME})..."
    if deck gateway sync "$KONG_FILE" \
        --konnect-addr "${KONNECT_REGIONAL_API}" \
        --konnect-token "$KONNECT_TOKEN" \
        --konnect-control-plane-name "$CP_NAME"; then
        info "  Kong routes synced successfully"
    else
        error "  Kong sync failed — check deck output above"
        warn "  Retry manually: deck gateway sync deck/kong.yaml --konnect-addr ${KONNECT_REGIONAL_API} --konnect-token \$KONNECT_TOKEN --konnect-control-plane-name ${CP_NAME}"
    fi
}

# ---------------------------------------------------------------------------
# Update Insomnia collection with the CloudFront URL
# ---------------------------------------------------------------------------
# Called every time a new environment is created so the GitHub Actions
# post-deployment test workflow always uses the correct base URL.
# Requires: jq (brew install jq)
# ---------------------------------------------------------------------------
update_insomnia_url() {
    local INSOMNIA_FILE="${REPO_DIR}/insomnia/munchgo-api.json"

    if [[ ! -f "$INSOMNIA_FILE" ]]; then
        warn "insomnia/munchgo-api.json not found — skipping Insomnia URL update"
        return
    fi

    if [[ -z "$APP_URL" ]]; then
        warn "CloudFront URL not available — insomnia/munchgo-api.json base_url not updated"
        warn "Re-run this script after 'terraform apply' with CloudFront enabled"
        return
    fi

    if ! command -v jq &>/dev/null; then
        warn "jq not found — skipping Insomnia URL update. Install with: brew install jq"
        return
    fi

    log "Updating insomnia/munchgo-api.json base_url → ${APP_URL}..."

    local TMP_FILE
    TMP_FILE=$(mktemp)

    jq --arg url "$APP_URL" \
        '(.resources[] | select(._type == "environment") | .data.base_url) = $url' \
        "$INSOMNIA_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$INSOMNIA_FILE"

    info "  Insomnia base_url → ${APP_URL}"
}

# ---------------------------------------------------------------------------
# Auto-resolve the Konnect control-plane ID
# ---------------------------------------------------------------------------
# Priority:
#   1. KONNECT_CP_ID already set in environment / .env
#   2. Terraform output konnect_control_plane_id (IaC path — zero manual steps)
#   3. Query Konnect API by KONNECT_CONTROL_PLANE_NAME (fallback)
#   4. Persist the resolved ID back to .env for future runs
#
# With the Terraform Konnect provider (terraform/konnect.tf), the CP ID is
# written to Terraform state on every 'terraform apply' and is always current —
# even after platform destroy/recreate. No manual entry ever needed.
# ---------------------------------------------------------------------------
get_konnect_cp_id() {
    # Priority 1: already in environment / .env
    if [[ -n "${KONNECT_CP_ID:-}" ]]; then
        info "  Konnect CP ID (from env): ${KONNECT_CP_ID}"
        return
    fi

    # Priority 2: read from Terraform output (IaC path)
    if [[ -d "$TERRAFORM_DIR/.terraform" ]]; then
        local TF_CP_ID
        TF_CP_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw konnect_control_plane_id 2>/dev/null || echo "")
        if [[ -n "$TF_CP_ID" && "$TF_CP_ID" != "null" ]]; then
            KONNECT_CP_ID="$TF_CP_ID"
            info "  Konnect CP ID (from terraform output): ${KONNECT_CP_ID}"
            # Persist so subsequent runs skip the Terraform call
            if [[ -f "$ENV_FILE" ]]; then
                if grep -q "^KONNECT_CP_ID=" "$ENV_FILE" 2>/dev/null; then
                    sed -i.bak "s|^KONNECT_CP_ID=.*|KONNECT_CP_ID=\"${KONNECT_CP_ID}\"|" "$ENV_FILE"
                    rm -f "${ENV_FILE}.bak"
                else
                    echo "KONNECT_CP_ID=\"${KONNECT_CP_ID}\"" >> "$ENV_FILE"
                fi
                info "  Persisted KONNECT_CP_ID to .env"
            fi
            return
        fi
    fi

    # Priority 3: fallback — query Konnect API by control-plane name
    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        warn "KONNECT_TOKEN not set — cannot look up CP ID, skipping Kong monitoring setup"
        return
    fi

    local CP_NAME="${KONNECT_CONTROL_PLANE_NAME:-MunchGo}"

    log "Looking up Konnect CP ID for control plane '${CP_NAME}' via API..."

    local RESPONSE
    # Use global API (Terraform creates CPs on the global endpoint)
    RESPONSE=$(curl -s \
        "${KONNECT_GLOBAL_API}/v2/control-planes?filter%5Bname%5D=${CP_NAME}" \
        -H "Authorization: Bearer ${KONNECT_TOKEN}" 2>/dev/null || echo "{}")

    KONNECT_CP_ID=$(echo "$RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    items = data.get('data', [])
    match = next((x for x in items if x.get('name') == '${CP_NAME}'), None)
    print(match['id'] if match else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

    if [[ -z "${KONNECT_CP_ID:-}" ]]; then
        warn "  Could not find control plane '${CP_NAME}' in Konnect"
        warn "  Run 'terraform apply' with konnect_token set, or run 02-setup-cloud-gateway.sh"
        return
    fi

    info "  Konnect CP ID (resolved from API): ${KONNECT_CP_ID}"

    # Persist to .env so subsequent runs skip the API call
    if [[ -f "$ENV_FILE" ]]; then
        if grep -q "^KONNECT_CP_ID=" "$ENV_FILE" 2>/dev/null; then
            sed -i.bak "s|^KONNECT_CP_ID=.*|KONNECT_CP_ID=\"${KONNECT_CP_ID}\"|" "$ENV_FILE"
            rm -f "${ENV_FILE}.bak"
        else
            echo "KONNECT_CP_ID=\"${KONNECT_CP_ID}\"" >> "$ENV_FILE"
        fi
        info "  Persisted KONNECT_CP_ID to .env"
    fi
}

# ---------------------------------------------------------------------------
# Create Konnect token K8s secret for the analytics exporter CronJob
# ---------------------------------------------------------------------------
# The konnect-analytics-exporter CronJob reads KONNECT_TOKEN and KONNECT_CP_ID
# from this secret to authenticate with the Konnect Analytics API.
# KONNECT_CP_ID is resolved automatically by get_konnect_cp_id() above.
# ---------------------------------------------------------------------------
create_konnect_token_secret() {
    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        warn "KONNECT_TOKEN not set — skipping konnect-token secret creation"
        return
    fi

    if [[ -z "${KONNECT_CP_ID:-}" ]]; then
        warn "KONNECT_CP_ID could not be resolved — skipping konnect-token secret creation"
        return
    fi

    log "Creating konnect-token secret in observability namespace..."
    kubectl create secret generic konnect-token \
        --from-literal=token="${KONNECT_TOKEN}" \
        --from-literal=cp_id="${KONNECT_CP_ID}" \
        -n observability \
        --dry-run=client -o yaml | kubectl apply -f -
    info "  konnect-token secret created (token + cp_id=${KONNECT_CP_ID})"
}

# ---------------------------------------------------------------------------
# Auto-discover Kong Cloud Gateway proxy domain
# ---------------------------------------------------------------------------
# The proxy domain changes on every rebuild. It follows the pattern:
#   <prefix>.gateways.konggateway.com
# where <prefix> is extracted from the CP endpoint:
#   https://<prefix>.<region>.cp0.konghq.com
# ---------------------------------------------------------------------------
discover_kong_proxy_domain() {
    log "Discovering Kong Cloud Gateway proxy domain..."

    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        warn "KONNECT_TOKEN not set — cannot discover proxy domain"
        return
    fi

    local CP_NAME="${KONNECT_CONTROL_PLANE_NAME:-MunchGo}"

    # Get CP endpoint from Konnect API
    local CP_RESPONSE
    CP_RESPONSE=$(curl -s "${KONNECT_REGIONAL_API}/v2/control-planes?filter%5Bname%5D=${CP_NAME}" \
        -H "Authorization: Bearer ${KONNECT_TOKEN}" 2>/dev/null || echo "{}")

    local CP_ENDPOINT
    CP_ENDPOINT=$(echo "$CP_RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    items = data.get('data', [])
    match = next((x for x in items if x.get('name') == '${CP_NAME}'), None)
    if match:
        print(match.get('config', {}).get('control_plane_endpoint', ''))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo "")

    if [[ -z "$CP_ENDPOINT" ]]; then
        warn "Could not discover CP endpoint — kong_cloud_gateway_domain not updated"
        return
    fi

    # Extract prefix: https://6de7e35936.us.cp0.konghq.com -> 6de7e35936
    local PREFIX
    PREFIX=$(echo "$CP_ENDPOINT" | sed -E 's|https://([^.]+)\..*|\1|')

    if [[ -z "$PREFIX" ]]; then
        warn "Could not parse CP endpoint prefix from: $CP_ENDPOINT"
        return
    fi

    KONG_PROXY_DOMAIN="${PREFIX}.gateways.konggateway.com"

    # Verify DNS resolves
    if ! nslookup "$KONG_PROXY_DOMAIN" &>/dev/null; then
        warn "Kong proxy domain ${KONG_PROXY_DOMAIN} does not resolve yet (may need a few minutes)"
    fi

    info "  Kong proxy domain: ${KONG_PROXY_DOMAIN}"

    # Update terraform.tfvars with the new proxy domain
    local TFVARS="${TERRAFORM_DIR}/terraform.tfvars"
    if [[ -f "$TFVARS" ]]; then
        if grep -q "^kong_cloud_gateway_domain" "$TFVARS"; then
            sed -i.bak "s|^kong_cloud_gateway_domain.*|kong_cloud_gateway_domain = \"${KONG_PROXY_DOMAIN}\"|" "$TFVARS"
        else
            echo "" >> "$TFVARS"
            echo "# Kong Cloud Gateway proxy domain (auto-discovered by 03-post-terraform-setup.sh)" >> "$TFVARS"
            echo "kong_cloud_gateway_domain = \"${KONG_PROXY_DOMAIN}\"" >> "$TFVARS"
        fi
        rm -f "${TFVARS}.bak"
        info "  Updated terraform.tfvars with kong_cloud_gateway_domain"
    fi

    # Re-apply terraform to update CloudFront origin with the new proxy domain
    if [[ -n "${KONG_PROXY_DOMAIN}" ]]; then
        log "Updating CloudFront origin with discovered proxy domain..."
        cd "$TERRAFORM_DIR"
        [[ -n "${KONNECT_TOKEN:-}" ]] && export TF_VAR_konnect_token="${KONNECT_TOKEN}"
        if terraform apply -var-file=terraform.tfvars -auto-approve -target='module.cloudfront' 2>/dev/null; then
            info "  CloudFront updated with Kong proxy domain"
        else
            warn "  CloudFront update failed — run manually: cd terraform && terraform apply"
        fi
        # Re-read CloudFront URL
        APP_URL=$(terraform output -raw application_url 2>/dev/null || echo "")
        cd "$REPO_DIR"
    fi
}

# ---------------------------------------------------------------------------
# Create ArgoCD repository credentials for private repos
# ---------------------------------------------------------------------------
# Uses a credential template (repo-creds) that matches all repos under
# github.com/shanaka-versent. This covers munchgo-k8s-config, munchgo-aws-iac,
# and any future private repos automatically.
# ---------------------------------------------------------------------------
create_argocd_repo_credentials() {
    log "Configuring ArgoCD repository credentials..."

    local GH_TOKEN="${ARGOCD_GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -z "$GH_TOKEN" ]]; then
        warn "ARGOCD_GH_TOKEN not set in .env — ArgoCD cannot access private repos"
        warn "Set ARGOCD_GH_TOKEN in .env and re-run, or create manually:"
        warn "  kubectl create secret generic argocd-repo-creds -n argocd \\"
        warn "    --from-literal=type=git \\"
        warn "    --from-literal=url=https://github.com/shanaka-versent \\"
        warn "    --from-literal=password=<GH_PAT> --from-literal=username=git"
        return
    fi

    # Wait for argocd namespace to exist (may take a moment after terraform apply)
    local wait=0
    while ! kubectl get ns argocd &>/dev/null && [[ $wait -lt 60 ]]; do
        sleep 5
        wait=$((wait + 5))
    done

    kubectl create secret generic argocd-repo-creds -n argocd \
        --from-literal=type=git \
        --from-literal=url="https://github.com/shanaka-versent" \
        --from-literal=password="$GH_TOKEN" \
        --from-literal=username=git \
        --dry-run=client -o yaml | \
        kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml | \
        kubectl apply -f -

    info "  ArgoCD credential template configured (github.com/shanaka-versent/*)"
}

# ---------------------------------------------------------------------------
# Verify VPC routes for Kong Cloud Gateway CIDR
# ---------------------------------------------------------------------------
# The VPC route for Kong CIDR (192.168.0.0/16) via Transit Gateway can drift
# from Terraform state after rebuilds. This function verifies the actual route
# exists in AWS and re-creates it if missing.
# ---------------------------------------------------------------------------
verify_vpc_routes() {
    log "Verifying VPC routes for Kong Cloud Gateway CIDR..."

    local KONG_CIDR="${KONG_CLOUD_GATEWAY_CIDR:-192.168.0.0/16}"

    if [[ "$VPC_ID" == "N/A" ]]; then
        warn "VPC ID not available — skipping route verification"
        return
    fi

    # Check if the route actually exists in AWS
    local ROUTE_EXISTS
    ROUTE_EXISTS=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query "RouteTables[].Routes[?DestinationCidrBlock=='${KONG_CIDR}' && State=='active'].DestinationCidrBlock" \
        --output text 2>/dev/null || echo "")

    if [[ -z "$ROUTE_EXISTS" ]]; then
        warn "Kong CIDR route (${KONG_CIDR}) missing from VPC route tables — recreating..."
        cd "$TERRAFORM_DIR"
        [[ -n "${KONNECT_TOKEN:-}" ]] && export TF_VAR_konnect_token="${KONNECT_TOKEN}"
        terraform apply -replace='aws_route.kong_cloud_gw[0]' \
            -var-file=terraform.tfvars -auto-approve 2>/dev/null || \
            warn "  Route recreation failed — run manually: terraform apply -replace='aws_route.kong_cloud_gw[0]'"
        cd "$REPO_DIR"
        info "  VPC routes recreated"
    else
        info "  VPC routes verified (active)"
    fi
}

# ---------------------------------------------------------------------------
# Update GitHub repository variables for CI/CD
# ---------------------------------------------------------------------------
# Updates GitHub Actions variables/secrets in munchgo-spa repo so that
# deploy workflows and E2E tests use the correct CloudFront URL, distribution
# ID, and S3 bucket name after each rebuild.
# ---------------------------------------------------------------------------
update_github_variables() {
    if ! command -v gh &>/dev/null; then
        warn "gh CLI not found — skipping GitHub variables update"
        warn "Install with: brew install gh"
        return
    fi

    if ! gh auth status &>/dev/null; then
        warn "gh CLI not authenticated — skipping GitHub variables update"
        warn "Run: gh auth login"
        return
    fi

    log "Updating GitHub repository variables..."

    local SPA_REPO="shanaka-versent/munchgo-spa"

    # CloudFront URL
    if [[ -n "$APP_URL" ]]; then
        gh variable set CLOUDFRONT_URL --body "$APP_URL" -R "$SPA_REPO" 2>/dev/null && \
            info "  ${SPA_REPO}: CLOUDFRONT_URL → ${APP_URL}" || \
            warn "  Failed to update CLOUDFRONT_URL in $SPA_REPO"
    fi

    # CloudFront Distribution ID
    local CF_DIST_ID
    CF_DIST_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw cloudfront_distribution_id 2>/dev/null || echo "")
    if [[ -n "$CF_DIST_ID" ]]; then
        gh variable set CLOUDFRONT_DISTRIBUTION_ID --body "$CF_DIST_ID" -R "$SPA_REPO" 2>/dev/null && \
            info "  ${SPA_REPO}: CLOUDFRONT_DISTRIBUTION_ID → ${CF_DIST_ID}" || \
            warn "  Failed to update CLOUDFRONT_DISTRIBUTION_ID in $SPA_REPO"
    fi

    # SPA Bucket Name
    local SPA_BUCKET
    SPA_BUCKET=$(cd "$TERRAFORM_DIR" && terraform output -raw spa_bucket_name 2>/dev/null || echo "")
    if [[ -n "$SPA_BUCKET" ]]; then
        gh variable set SPA_BUCKET_NAME --body "$SPA_BUCKET" -R "$SPA_REPO" 2>/dev/null && \
            info "  ${SPA_REPO}: SPA_BUCKET_NAME → ${SPA_BUCKET}" || \
            warn "  Failed to update SPA_BUCKET_NAME in $SPA_REPO"
    fi
}

# ---------------------------------------------------------------------------
# Show next steps
# ---------------------------------------------------------------------------
show_next_steps() {
    echo ""
    echo "=========================================="
    echo "  Infrastructure Configuration Complete"
    echo "=========================================="
    echo ""
    echo "  Completed:"
    echo "    - Kong proxy domain discovered and CloudFront updated"
    echo "    - ArgoCD repository credentials configured"
    echo "    - VPC routes verified"
    echo "    - Config placeholders populated (kong.yaml, ExternalSecrets)"
    echo "    - Service databases created"
    echo "    - Kong routes synced to Konnect"
    echo "    - Konnect analytics secret configured"
    echo "    - GitHub CI/CD variables updated"
    echo ""
    echo "  Next step — deploy applications:"
    echo "    ./scripts/04-deploy-apps.sh"
    echo ""
    echo "  This will:"
    echo "    - Trigger all 6 microservice CI workflows (ECR push)"
    echo "    - Trigger SPA build + deploy to S3"
    echo "    - Wait for CI completion and pod rollouts"
    echo "    - Seed admin user and demo data"
    echo "    - Run smoke tests on all endpoints"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Post-Terraform Setup — Kong Cloud Gateway"
    echo "  Automated Endpoint Discovery & Configuration"
    echo "=============================================="
    echo ""

    read_terraform_outputs
    discover_kong_proxy_domain
    create_argocd_repo_credentials
    verify_vpc_routes
    get_gateway_endpoint
    generate_gateway_tls
    populate_kong_yaml
    populate_external_secrets
    populate_eso_irsa
    populate_k8s_overlay
    update_insomnia_url
    create_service_databases
    create_kafka_secret
    sync_kong_config
    get_konnect_cp_id
    create_konnect_token_secret
    update_github_variables
    show_next_steps
}

main "$@"
