# Kong Konnect Cloud Gateway — Terraform IaC
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Declarative management of Kong Konnect Dedicated Cloud Gateway resources
# via the kong/konnect Terraform provider.
#
# What Terraform manages (fast, idempotent):
#   - Control Plane
#   - Cloud Gateway Network
#   - Data Plane Group Configuration
#
# What the script handles (requires ~30 min wait for network 'ready'):
#   - Transit Gateway attachment → scripts/02-setup-cloud-gateway.sh --tgw-only
#     (uses the battle-tested wait loop from the original implementation)
#
# Token source (in priority order):
#   1. TF_VAR_konnect_token environment variable (CI/CD — from GitHub secret)
#   2. terraform.tfvars entry: konnect_token = "kpat_..."
#   3. Source .env then: export TF_VAR_konnect_token="$(grep KONNECT_TOKEN .env | cut -d'"' -f2)"
#
# If konnect_token is empty (var default ""), all Konnect resources are skipped.
# ==============================================================================

# Guard: only create Konnect resources when token is provided
locals {
  konnect_enabled = var.konnect_token != ""
}

# ---------------------------------------------------------------------------
# Data: look up Kong's AWS provider account linked to this Konnect org
# ---------------------------------------------------------------------------
data "konnect_cloud_gateway_provider_accounts" "main" {
  count = local.konnect_enabled ? 1 : 0
}

locals {
  # First AWS provider account in the org (typically only one per region)
  aws_provider_account_id = local.konnect_enabled ? (
    length([
      for a in data.konnect_cloud_gateway_provider_accounts.main[0].data :
      a.id if a.provider == "aws"
    ]) > 0 ? [
      for a in data.konnect_cloud_gateway_provider_accounts.main[0].data :
      a.id if a.provider == "aws"
    ][0] : ""
  ) : ""
}

# ---------------------------------------------------------------------------
# Control Plane
# ---------------------------------------------------------------------------
resource "konnect_gateway_control_plane" "munchgo" {
  count = local.konnect_enabled ? 1 : 0

  name          = var.konnect_control_plane_name
  cluster_type  = "CLUSTER_TYPE_CONTROL_PLANE"
  cloud_gateway = true

  labels = {
    env        = var.environment
    type       = "cloud-gateway"
    managed-by = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Cloud Gateway Network (Kong-managed VPC in ap-southeast-2)
#
# Note: Provisioning takes ~30 minutes to reach 'ready' state.
# The Transit Gateway attachment runs AFTER the network is ready —
# handled by: ./scripts/02-setup-cloud-gateway.sh --tgw-only
# ---------------------------------------------------------------------------
resource "konnect_cloud_gateway_network" "munchgo" {
  count = local.konnect_enabled && local.aws_provider_account_id != "" ? 1 : 0

  name                              = "munchgo-eks-network"
  cloud_gateway_provider_account_id = local.aws_provider_account_id
  region                            = "ap-southeast-2"
  availability_zones                = ["apse2-az1", "apse2-az2"]
  cidr_block                        = var.kong_cloud_gateway_cidr
}

# ---------------------------------------------------------------------------
# Data Plane Group Configuration (autopilot, linked to the network above)
# ---------------------------------------------------------------------------
resource "konnect_cloud_gateway_configuration" "munchgo" {
  count = local.konnect_enabled && length(konnect_gateway_control_plane.munchgo) > 0 && length(konnect_cloud_gateway_network.munchgo) > 0 ? 1 : 0

  control_plane_id  = konnect_gateway_control_plane.munchgo[0].id
  version           = "3.9"
  control_plane_geo = var.konnect_region

  dataplane_groups = [
    {
      provider                 = "aws"
      region                   = "ap-southeast-2"
      cloud_gateway_network_id = konnect_cloud_gateway_network.munchgo[0].id
      autoscale = {
        kind     = "autopilot"
        base_rps = 100
      }
    }
  ]
}
