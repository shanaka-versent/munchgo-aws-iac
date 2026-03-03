# Kong Konnect Cloud Gateway — Terraform IaC
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Declarative management of Kong Konnect Dedicated Cloud Gateway resources.
# This replaces scripts/02-setup-cloud-gateway.sh for the control plane,
# network, and data plane group. The Transit Gateway attachment is also
# managed here but must be applied in a second pass once the network is ready.
#
# Token source (in priority order):
#   1. TF_VAR_konnect_token environment variable (CI/CD — from GitHub secret)
#   2. terraform.tfvars entry: konnect_token = "kpat_..."
#   3. .env file sourced before running terraform (auto-populates TF_VAR_konnect_token)
#
# Usage:
#   # Pass 1 — provision AWS + Konnect control plane + network + data plane group
#   terraform apply
#
#   # Wait ~30 min for Cloud Gateway Network to reach 'ready' state, then:
#   # Pass 2 — attach Transit Gateway (network must be ready)
#   terraform apply -target=konnect_cloud_gateway_transit_gateway.eks
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
# Provisioning takes ~30 minutes. Do not proceed with TGW attachment
# until 'terraform show' confirms network state = "ready".
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

# ---------------------------------------------------------------------------
# Transit Gateway Attachment
# IMPORTANT: Only apply AFTER the network is in 'ready' state (~30 min):
#   terraform apply -target=konnect_cloud_gateway_transit_gateway.eks
#
# The network CIDR (192.168.0.0/16) is Kong's managed VPC — traffic destined
# for EKS backend services flows: Kong DCGW → TGW → EKS VPC.
# ---------------------------------------------------------------------------
resource "konnect_cloud_gateway_transit_gateway" "eks" {
  count = local.konnect_enabled && length(konnect_cloud_gateway_network.munchgo) > 0 ? 1 : 0

  name       = "eks-transit-gateway"
  network_id = konnect_cloud_gateway_network.munchgo[0].id

  # Route EKS VPC traffic through this TGW attachment
  cidr_blocks = [module.vpc.vpc_cidr]

  transit_gateway_attachment_config = {
    kind               = "aws-transit-gateway-attachment"
    transit_gateway_id = aws_ec2_transit_gateway.kong.id
    ram_share_arn      = aws_ram_resource_share.kong_tgw.arn
  }

  # TGW attachment requires the network AND the RAM share to be in place
  depends_on = [
    konnect_cloud_gateway_network.munchgo,
    aws_ram_resource_association.kong_tgw,
  ]
}
