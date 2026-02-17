#!/bin/bash
# MunchGo — Seed Demo Data (Restaurants, Menu Items)
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Populates the modernised microservices with sample data matching
# the monolith's V3__seed_demo_data.sql migration, so both apps
# look identical when browsing restaurants.
#
# Creates:
#   - MunchGo Burger Palace (7 menu items)
#   - MunchGo Pizza House   (6 menu items)
#   - MunchGo Sushi Bar     (6 menu items)
#
# Prerequisites:
#   - Stack deployed (CloudFront + Kong + services running)
#   - Admin user seeded (04-seed-admin-user.sh)
#
# Usage:
#   ./scripts/05-seed-demo-data.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${CYAN}[DATA]${NC} $*"; }

# ---------------------------------------------------------------------------
# Read application URL from Terraform
# ---------------------------------------------------------------------------
get_app_url() {
    log "Reading application URL from Terraform outputs..."
    cd "$TERRAFORM_DIR"
    APP_URL=$(terraform output -raw application_url 2>/dev/null || echo "")
    cd "$REPO_DIR"

    if [[ -z "$APP_URL" ]]; then
        error "application_url not found. Run 'terraform apply' first."
        exit 1
    fi
    info "Application URL: $APP_URL"
}

# ---------------------------------------------------------------------------
# Login as admin to get access token
# ---------------------------------------------------------------------------
login_admin() {
    log "Logging in as admin@munchgo.com..."

    LOGIN_RESPONSE=$(curl -sf -X POST "${APP_URL}/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"email":"admin@munchgo.com","password":"Admin@123"}' 2>&1) || {
        error "Login failed. Make sure the admin user is seeded (04-seed-admin-user.sh)."
        error "Response: $LOGIN_RESPONSE"
        exit 1
    }

    ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['accessToken'])" 2>/dev/null) || {
        error "Failed to extract access token from login response."
        error "Response: $LOGIN_RESPONSE"
        exit 1
    }

    info "Admin login successful"
}

# ---------------------------------------------------------------------------
# Helper: create a restaurant and capture its ID
# ---------------------------------------------------------------------------
create_restaurant() {
    local name="$1"
    local street1="$2"
    local city="$3"
    local state="$4"
    local zip="$5"
    local order_min="$6"

    log "Creating restaurant: $name"

    local response
    response=$(curl -sf -X POST "${APP_URL}/api/v1/restaurants" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -d "$(cat <<JSONEOF
{
  "name": "$name",
  "address": {
    "street1": "$street1",
    "city": "$city",
    "state": "$state",
    "zip": "$zip",
    "country": "US"
  },
  "orderMinimum": $order_min
}
JSONEOF
)" 2>&1) || {
        warn "Restaurant '$name' may already exist or request failed."
        warn "Response: $response"
        echo ""
        return 1
    }

    local rid
    rid=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null) || {
        warn "Could not extract restaurant ID from response."
        echo ""
        return 1
    }

    info "  Created restaurant: $name (ID: $rid)"
    echo "$rid"
}

# ---------------------------------------------------------------------------
# Helper: add a menu item to a restaurant
# ---------------------------------------------------------------------------
add_menu_item() {
    local restaurant_id="$1"
    local item_id="$2"
    local name="$3"
    local price="$4"
    local description="${5:-}"

    curl -sf -X POST "${APP_URL}/api/v1/restaurants/${restaurant_id}/menu-items" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -d "$(cat <<JSONEOF
{
  "menuItemId": "$item_id",
  "name": "$name",
  "price": $price,
  "description": "$description"
}
JSONEOF
)" > /dev/null 2>&1 || {
        warn "  Failed to add menu item: $name"
        return 1
    }

    info "  + $name (\$$price)"
}

# ---------------------------------------------------------------------------
# Seed Restaurant 1: MunchGo Burger Palace (matches monolith V3 migration)
# ---------------------------------------------------------------------------
seed_burger_palace() {
    local rid
    rid=$(create_restaurant \
        "MunchGo Burger Palace" \
        "123 Main St" "Springfield" "IL" "62701" "5.00")

    if [[ -z "$rid" ]]; then
        warn "Skipping menu items for MunchGo Burger Palace"
        return
    fi

    add_menu_item "$rid" "BURGER_01" "Classic Burger"  9.99  "Angus beef patty, lettuce, tomato, onion, pickles"
    add_menu_item "$rid" "BURGER_02" "Cheese Burger"  11.49  "Classic burger with melted cheddar"
    add_menu_item "$rid" "BURGER_03" "Bacon Burger"   13.99  "Smoked bacon, cheddar, BBQ sauce"
    add_menu_item "$rid" "FRIES_01"  "Regular Fries"   4.49  "Crispy golden fries"
    add_menu_item "$rid" "FRIES_02"  "Loaded Fries"    7.99  "Fries with cheese, bacon, sour cream"
    add_menu_item "$rid" "DRINK_01"  "Soft Drink"      2.49  "Coke, Sprite, or Fanta"
    add_menu_item "$rid" "DRINK_02"  "Milkshake"       5.99  "Vanilla, chocolate, or strawberry"
    echo ""
}

# ---------------------------------------------------------------------------
# Seed Restaurant 2: MunchGo Pizza House
# ---------------------------------------------------------------------------
seed_pizza_house() {
    local rid
    rid=$(create_restaurant \
        "MunchGo Pizza House" \
        "456 Oak Ave" "Springfield" "IL" "62702" "8.00")

    if [[ -z "$rid" ]]; then
        warn "Skipping menu items for MunchGo Pizza House"
        return
    fi

    add_menu_item "$rid" "PIZZA_01"  "Margherita Pizza"     12.99 "Fresh mozzarella, basil, San Marzano tomatoes"
    add_menu_item "$rid" "PIZZA_02"  "Pepperoni Pizza"      14.99 "Classic pepperoni with mozzarella"
    add_menu_item "$rid" "PIZZA_03"  "BBQ Chicken Pizza"    16.49 "Grilled chicken, BBQ sauce, red onion, cilantro"
    add_menu_item "$rid" "SIDE_01"   "Garlic Bread"          5.99 "Toasted with garlic butter and herbs"
    add_menu_item "$rid" "SIDE_02"   "Caesar Salad"          7.49 "Romaine, parmesan, croutons, caesar dressing"
    add_menu_item "$rid" "DRINK_03"  "Iced Tea"              2.99 "Freshly brewed, sweetened or unsweetened"
    echo ""
}

# ---------------------------------------------------------------------------
# Seed Restaurant 3: MunchGo Sushi Bar
# ---------------------------------------------------------------------------
seed_sushi_bar() {
    local rid
    rid=$(create_restaurant \
        "MunchGo Sushi Bar" \
        "789 Elm Blvd" "Springfield" "IL" "62703" "10.00")

    if [[ -z "$rid" ]]; then
        warn "Skipping menu items for MunchGo Sushi Bar"
        return
    fi

    add_menu_item "$rid" "SUSHI_01"  "Salmon Nigiri (2pc)"   6.99 "Fresh Atlantic salmon on seasoned rice"
    add_menu_item "$rid" "SUSHI_02"  "Tuna Sashimi (5pc)"    9.99 "Premium yellowfin tuna"
    add_menu_item "$rid" "ROLL_01"   "California Roll (8pc)" 8.49 "Crab, avocado, cucumber"
    add_menu_item "$rid" "ROLL_02"   "Dragon Roll (8pc)"    13.99 "Shrimp tempura, eel, avocado"
    add_menu_item "$rid" "SIDE_03"   "Miso Soup"             3.49 "Traditional dashi broth with tofu and wakame"
    add_menu_item "$rid" "SIDE_04"   "Edamame"               4.49 "Steamed soybeans with sea salt"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  MunchGo — Seed Demo Data"
    echo "=============================================="
    echo ""

    get_app_url
    login_admin
    echo ""

    log "Seeding restaurants and menu items..."
    echo ""

    seed_burger_palace
    seed_pizza_house
    seed_sushi_bar

    echo "=========================================="
    echo "  Demo Data Seeded Successfully"
    echo "=========================================="
    echo ""
    echo "  Restaurants:"
    echo "    1. MunchGo Burger Palace  (7 items)"
    echo "    2. MunchGo Pizza House    (6 items)"
    echo "    3. MunchGo Sushi Bar      (6 items)"
    echo ""
    echo "  Browse at: ${APP_URL}"
    echo ""
}

main "$@"
