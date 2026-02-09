#!/bin/bash
# Kong Cloud Gateway on EKS — Seed Default Admin User
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Creates a default admin user in Amazon Cognito and the auth-service database.
# Mirrors the monolith's admin/admin123 seed from V2__add_users_and_roles.sql.
#
# Default Admin Credentials:
#   Email:    admin@munchgo.com
#   Password: Admin@123
#   Role:     ROLE_ADMIN
#
# Cognito password policy requires: min 8 chars, uppercase, lowercase, number, symbol.
#
# Prerequisites:
#   - Terraform applied (Cognito User Pool exists)
#   - EKS cluster reachable (for DB seed via kubectl)
#   - AWS CLI configured with appropriate permissions
#
# Usage:
#   ./scripts/04-seed-admin-user.sh

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
info() { echo -e "${CYAN}[CONFIG]${NC} $*"; }

# ---------------------------------------------------------------------------
# Default Admin Credentials
# ---------------------------------------------------------------------------
ADMIN_EMAIL="admin@munchgo.com"
ADMIN_PASSWORD="Admin@123"
ADMIN_USERNAME="admin"
ADMIN_FIRST_NAME="System"
ADMIN_LAST_NAME="Admin"
ADMIN_ROLE="ROLE_ADMIN"

# ---------------------------------------------------------------------------
# Read Cognito outputs from Terraform
# ---------------------------------------------------------------------------
read_cognito_config() {
    log "Reading Cognito configuration from Terraform outputs..."

    cd "$TERRAFORM_DIR"

    USER_POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null || echo "")
    APP_CLIENT_ID=$(terraform output -raw cognito_app_client_id 2>/dev/null || echo "")
    AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "ap-southeast-2")

    cd "$REPO_DIR"

    if [[ -z "$USER_POOL_ID" ]]; then
        error "Cognito User Pool ID not found. Run 'terraform apply' first."
        exit 1
    fi

    info "User Pool ID:  $USER_POOL_ID"
    info "App Client ID: $APP_CLIENT_ID"
    info "Region:        $AWS_REGION"
}

# ---------------------------------------------------------------------------
# Ensure ROLE_ADMIN group exists in Cognito
# ---------------------------------------------------------------------------
ensure_admin_group() {
    log "Ensuring ROLE_ADMIN group exists in Cognito..."

    if aws cognito-idp get-group \
        --user-pool-id "$USER_POOL_ID" \
        --group-name "$ADMIN_ROLE" \
        --region "$AWS_REGION" &>/dev/null; then
        info "Group $ADMIN_ROLE already exists"
    else
        aws cognito-idp create-group \
            --user-pool-id "$USER_POOL_ID" \
            --group-name "$ADMIN_ROLE" \
            --description "MunchGo platform administrators" \
            --region "$AWS_REGION"
        info "Created group: $ADMIN_ROLE"
    fi
}

# ---------------------------------------------------------------------------
# Create admin user in Cognito
# ---------------------------------------------------------------------------
create_cognito_admin() {
    log "Creating admin user in Cognito..."

    # Check if user already exists
    if aws cognito-idp admin-get-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$ADMIN_EMAIL" \
        --region "$AWS_REGION" &>/dev/null; then
        warn "Admin user already exists in Cognito: $ADMIN_EMAIL"
        COGNITO_SUB=$(aws cognito-idp admin-get-user \
            --user-pool-id "$USER_POOL_ID" \
            --username "$ADMIN_EMAIL" \
            --region "$AWS_REGION" \
            --query 'UserAttributes[?Name==`sub`].Value' \
            --output text)
        info "Existing Cognito sub: $COGNITO_SUB"
        return
    fi

    # Create user (suppress welcome email)
    aws cognito-idp admin-create-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$ADMIN_EMAIL" \
        --temporary-password "$ADMIN_PASSWORD" \
        --message-action SUPPRESS \
        --user-attributes \
            Name=email,Value="$ADMIN_EMAIL" \
            Name=email_verified,Value=true \
            Name=given_name,Value="$ADMIN_FIRST_NAME" \
            Name=family_name,Value="$ADMIN_LAST_NAME" \
        --region "$AWS_REGION" > /dev/null

    # Set permanent password (skip FORCE_CHANGE_PASSWORD)
    aws cognito-idp admin-set-user-password \
        --user-pool-id "$USER_POOL_ID" \
        --username "$ADMIN_EMAIL" \
        --password "$ADMIN_PASSWORD" \
        --permanent \
        --region "$AWS_REGION"

    # Add to ROLE_ADMIN group
    aws cognito-idp admin-add-user-to-group \
        --user-pool-id "$USER_POOL_ID" \
        --username "$ADMIN_EMAIL" \
        --group-name "$ADMIN_ROLE" \
        --region "$AWS_REGION"

    # Get Cognito sub
    COGNITO_SUB=$(aws cognito-idp admin-get-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$ADMIN_EMAIL" \
        --region "$AWS_REGION" \
        --query 'UserAttributes[?Name==`sub`].Value' \
        --output text)

    info "Created admin user: $ADMIN_EMAIL"
    info "Cognito sub: $COGNITO_SUB"
}

# ---------------------------------------------------------------------------
# Seed admin user in auth-service database
# ---------------------------------------------------------------------------
seed_auth_database() {
    log "Seeding admin user in auth-service database..."

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
            warn "munchgo-db-master secret not found after ${MAX_WAIT}s — skipping DB seed"
            warn "Run manually after ExternalSecrets syncs: ./scripts/04-seed-admin-user.sh"
            return
        fi
    fi

    # Clean up any previous seed job
    kubectl delete job admin-seed -n munchgo 2>/dev/null || true

    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: admin-seed
  namespace: munchgo
spec:
  ttlSecondsAfterFinished: 120
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
          command: ["sh", "-c"]
          args:
            - |
              # Seed admin in auth database
              psql -d auth -c "
                INSERT INTO users (id, username, email, cognito_sub, first_name, last_name, enabled, version, created_at, updated_at)
                VALUES (
                  '00000000-0000-0000-0000-000000000001',
                  '${ADMIN_USERNAME}',
                  '${ADMIN_EMAIL}',
                  '${COGNITO_SUB}',
                  '${ADMIN_FIRST_NAME}',
                  '${ADMIN_LAST_NAME}',
                  true,
                  0,
                  NOW(),
                  NOW()
                )
                ON CONFLICT (email) DO NOTHING;
              " && echo "Auth user seeded" || echo "Auth user may already exist"

              psql -d auth -c "
                INSERT INTO user_roles (user_id, role)
                SELECT '00000000-0000-0000-0000-000000000001', '${ADMIN_ROLE}'
                WHERE NOT EXISTS (
                  SELECT 1 FROM user_roles
                  WHERE user_id = '00000000-0000-0000-0000-000000000001'
                    AND role = '${ADMIN_ROLE}'
                );
              " && echo "Admin role assigned" || echo "Admin role may already exist"
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
  backoffLimit: 1
EOF

    # Wait for job to complete
    kubectl wait --for=condition=complete job/admin-seed -n munchgo --timeout=120s 2>/dev/null || \
        warn "Admin seed job did not complete in time — check: kubectl logs job/admin-seed -n munchgo"

    info "Admin user seeded in auth database"
}

# ---------------------------------------------------------------------------
# Show summary
# ---------------------------------------------------------------------------
show_summary() {
    echo ""
    echo "=========================================="
    echo "  Default Admin User Created"
    echo "=========================================="
    echo ""
    echo "  Email:    $ADMIN_EMAIL"
    echo "  Password: $ADMIN_PASSWORD"
    echo "  Role:     $ADMIN_ROLE"
    echo ""
    echo "  Login at the MunchGo SPA or via API:"
    echo "    curl -X POST https://<cloudfront-url>/api/v1/auth/login \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}'"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  MunchGo — Seed Default Admin User"
    echo "=============================================="
    echo ""

    read_cognito_config
    ensure_admin_group
    create_cognito_admin
    seed_auth_database
    show_summary
}

main "$@"
