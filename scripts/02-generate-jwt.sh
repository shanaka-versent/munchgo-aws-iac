#!/bin/bash
# Kong Cloud Gateway on EKS — Generate Cognito Test Tokens
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Registers a test user in Cognito and returns access/ID/refresh tokens.
# Uses Terraform outputs to discover Cognito User Pool and App Client IDs.
#
# Prerequisites:
#   - AWS CLI configured with credentials
#   - Terraform state available (terraform outputs)
#
# Usage:
#   ./scripts/02-generate-jwt.sh                        # Register + login test user
#   ./scripts/02-generate-jwt.sh login user@example.com  # Login existing user
#
# The generated token can be used as:
#   curl -H "Authorization: Bearer <access_token>" <APP_URL>/api/orders

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Read Cognito config from Terraform outputs
# ---------------------------------------------------------------------------
read_cognito_config() {
    log "Reading Cognito config from Terraform outputs..."
    cd "$TERRAFORM_DIR"

    USER_POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null) || error "Cannot read cognito_user_pool_id. Run 'terraform apply' first."
    APP_CLIENT_ID=$(terraform output -raw cognito_app_client_id 2>/dev/null) || error "Cannot read cognito_app_client_id."
    COGNITO_REGION=$(terraform output -raw region 2>/dev/null || echo "ap-southeast-2")

    cd - > /dev/null
    log "User Pool: ${USER_POOL_ID}"
    log "Client ID: ${APP_CLIENT_ID}"
    log "Region:    ${COGNITO_REGION}"
}

# ---------------------------------------------------------------------------
# Register a test user
# ---------------------------------------------------------------------------
register_test_user() {
    local EMAIL="${1:-testuser@munchgo.local}"
    local PASSWORD="${2:-TestPass123!}"
    local ROLE="${3:-ROLE_CUSTOMER}"

    log "Registering test user: ${EMAIL} (role: ${ROLE})..."

    # Create the user
    aws cognito-idp admin-create-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$EMAIL" \
        --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
        --region "$COGNITO_REGION" \
        --no-cli-pager > /dev/null 2>&1 || {
            warn "User may already exist, attempting login..."
            return 0
        }

    # Set permanent password (skip FORCE_CHANGE_PASSWORD)
    aws cognito-idp admin-set-user-password \
        --user-pool-id "$USER_POOL_ID" \
        --username "$EMAIL" \
        --password "$PASSWORD" \
        --permanent \
        --region "$COGNITO_REGION" \
        --no-cli-pager

    # Add to group
    aws cognito-idp admin-add-user-to-group \
        --user-pool-id "$USER_POOL_ID" \
        --username "$EMAIL" \
        --group-name "$ROLE" \
        --region "$COGNITO_REGION" \
        --no-cli-pager 2>/dev/null || warn "Group ${ROLE} may not exist yet"

    log "User registered successfully"
}

# ---------------------------------------------------------------------------
# Authenticate and get tokens
# ---------------------------------------------------------------------------
authenticate() {
    local EMAIL="${1:-testuser@munchgo.local}"
    local PASSWORD="${2:-TestPass123!}"

    log "Authenticating ${EMAIL}..."

    AUTH_RESULT=$(aws cognito-idp admin-initiate-auth \
        --user-pool-id "$USER_POOL_ID" \
        --client-id "$APP_CLIENT_ID" \
        --auth-flow ADMIN_USER_PASSWORD_AUTH \
        --auth-parameters USERNAME="$EMAIL",PASSWORD="$PASSWORD" \
        --region "$COGNITO_REGION" \
        --no-cli-pager 2>&1) || error "Authentication failed: ${AUTH_RESULT}"

    ACCESS_TOKEN=$(echo "$AUTH_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['AuthenticationResult']['AccessToken'])")
    ID_TOKEN=$(echo "$AUTH_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['AuthenticationResult']['IdToken'])")
    REFRESH_TOKEN=$(echo "$AUTH_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['AuthenticationResult']['RefreshToken'])")

    log "Authentication successful"
}

# ---------------------------------------------------------------------------
# Display tokens
# ---------------------------------------------------------------------------
display_tokens() {
    local EMAIL="${1:-testuser@munchgo.local}"

    # Decode access token payload for info
    PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null || echo '{}')
    EXP=$(echo "$PAYLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exp','N/A'))" 2>/dev/null || echo "N/A")
    SUB=$(echo "$PAYLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sub','N/A'))" 2>/dev/null || echo "N/A")

    echo ""
    echo "=========================================="
    echo "  Cognito Tokens — ${EMAIL}"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}User Sub:${NC}     ${SUB}"
    echo -e "${CYAN}Expires:${NC}      $(date -r "$EXP" 2>/dev/null || date -d "@$EXP" 2>/dev/null || echo "$EXP")"
    echo ""
    echo -e "${GREEN}Access Token:${NC}"
    echo "${ACCESS_TOKEN}"
    echo ""
    echo -e "${GREEN}ID Token:${NC}"
    echo "${ID_TOKEN}"
    echo ""
    echo -e "${GREEN}Refresh Token:${NC}"
    echo "${REFRESH_TOKEN}"
    echo ""
    echo "=========================================="
    echo "  Usage"
    echo "=========================================="
    echo ""

    # Try to get the app URL from Terraform
    APP_URL=$(cd "$TERRAFORM_DIR" && terraform output -raw application_url 2>/dev/null || echo "\${APP_URL}")
    cd - > /dev/null 2>&1

    echo "  # Health check (public)"
    echo "  curl ${APP_URL}/api/auth/health"
    echo ""
    echo "  # Protected API call (requires token)"
    echo "  curl -H \"Authorization: Bearer ${ACCESS_TOKEN:0:40}...\" ${APP_URL}/api/orders"
    echo ""
    echo "  # Full command:"
    echo "  export ACCESS_TOKEN=\"${ACCESS_TOKEN}\""
    echo "  curl -H \"Authorization: Bearer \$ACCESS_TOKEN\" ${APP_URL}/api/orders"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Cognito Test Token Generator"
    echo "=============================================="
    echo ""

    read_cognito_config

    local MODE="${1:-register}"
    local EMAIL="${2:-testuser@munchgo.local}"
    local PASSWORD="${3:-TestPass123!}"

    if [[ "$MODE" == "login" ]]; then
        authenticate "$EMAIL" "$PASSWORD"
    else
        register_test_user "$EMAIL" "$PASSWORD" "ROLE_CUSTOMER"
        authenticate "$EMAIL" "$PASSWORD"
    fi

    display_tokens "$EMAIL"
}

main "$@"
