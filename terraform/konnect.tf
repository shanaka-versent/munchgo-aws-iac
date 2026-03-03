# Kong Konnect Cloud Gateway — Terraform IaC
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Declarative management of Kong Konnect Dedicated Cloud Gateway resources.
# Replaces scripts/02-setup-cloud-gateway.sh entirely.
#
# Single 'terraform apply' handles the full lifecycle:
#   1. Create control plane + network + data plane group (instant)
#   2. Poll Konnect API until network reaches 'ready' (~30 min, in-process)
#   3. Attach Transit Gateway (only once network is confirmed ready)
#
# Token source (in priority order):
#   1. TF_VAR_konnect_token environment variable (CI/CD — from GitHub secret)
#   2. terraform.tfvars entry: konnect_token = "kpat_..."
#   3. Source .env then export TF_VAR_konnect_token (local dev)
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
# Provisioning takes ~30 minutes — the null_resource below handles the wait.
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
# Wait for network to reach 'ready' state before attaching Transit Gateway
#
# Polls the Konnect API every 30 seconds for up to 45 minutes (90 attempts).
# This runs inline during 'terraform apply' — no second pass needed.
# Re-triggers only if the network ID changes (i.e., after destroy/recreate).
# ---------------------------------------------------------------------------
resource "null_resource" "wait_for_network_ready" {
  count = local.konnect_enabled && length(konnect_cloud_gateway_network.munchgo) > 0 ? 1 : 0

  triggers = {
    network_id = konnect_cloud_gateway_network.munchgo[0].id
  }

  provisioner "local-exec" {
    command = <<-EOF
      NETWORK_ID="${konnect_cloud_gateway_network.munchgo[0].id}"
      TOKEN="${var.konnect_token}"
      echo "[Konnect] Waiting for network $NETWORK_ID to reach 'ready' state (~30 min)..."
      for i in $(seq 1 90); do
        STATE=$(curl -s \
          -H "Authorization: Bearer $TOKEN" \
          "https://global.api.konghq.com/v2/cloud-gateways/networks/$NETWORK_ID" \
          | python3 -c "import json,sys; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null || echo "error")
        echo "[Konnect] Attempt $i/90: network state = $STATE"
        if [ "$STATE" = "ready" ]; then
          echo "[Konnect] Network is ready."
          exit 0
        fi
        sleep 30
      done
      echo "[Konnect] ERROR: network did not reach 'ready' in 45 minutes."
      exit 1
    EOF
  }

  depends_on = [konnect_cloud_gateway_network.munchgo]
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
#
# Runs only AFTER null_resource.wait_for_network_ready confirms the network
# is ready. The full sequence runs in a single 'terraform apply'.
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

  depends_on = [
    null_resource.wait_for_network_ready,
    aws_ram_resource_association.kong_tgw,
  ]
}
