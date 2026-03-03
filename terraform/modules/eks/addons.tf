# EKS Add-ons
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Configures the VPC CNI add-on with the NetworkPolicy controller enabled.
# This activates kernel-level (eBPF) enforcement of Kubernetes NetworkPolicy
# resources — independent of Istio — providing the second enforcement layer
# in the defence-in-depth security stack.
#
# Enforcement stack (all three layers must be in place):
#   L3/L4  → Kubernetes NetworkPolicy  (VPC CNI eBPF — this add-on)
#   L4 mTLS → Istio PeerAuthentication + ztunnel HBONE
#   L7      → Istio AuthorizationPolicy + waypoint proxy
#
# Without this add-on configured, NetworkPolicy resources are stored in etcd
# but have NO enforcement effect. VPC CNI v1.14+ is required.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  tags = var.tags

  depends_on = [
    aws_eks_node_group.system
  ]
}
