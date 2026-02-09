# EKS Module
# @author Shanaka Jayasundera - shanakaj@gmail.com

# IAM Role for EKS Cluster
resource "aws_iam_role" "cluster" {
  name = "role-eks-cluster-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# IAM Role for Node Groups
resource "aws_iam_role" "node" {
  name = "role-eks-node-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  enabled_cluster_log_types = var.enable_logging ? ["api", "audit", "authenticator", "controllerManager", "scheduler"] : []

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

# OIDC Provider for IRSA
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = var.tags
}

# System Node Group (with taint for critical add-ons)
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name_prefix}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.node_subnet_ids
  instance_types  = [var.system_node_instance_type]

  scaling_config {
    desired_size = var.system_node_count
    min_size     = var.enable_autoscaling ? var.system_node_min_count : var.system_node_count
    max_size     = var.enable_autoscaling ? var.system_node_max_count : var.system_node_count
  }

  # Taint for system workloads only
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "node-role" = "system"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-system-node"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]
}

# User Node Group (no taint - for application workloads)
resource "aws_eks_node_group" "user" {
  count = var.enable_user_node_pool ? 1 : 0

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name_prefix}-user"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.node_subnet_ids
  instance_types  = [var.user_node_instance_type]

  scaling_config {
    desired_size = var.user_node_count
    min_size     = var.enable_autoscaling ? var.user_node_min_count : var.user_node_count
    max_size     = var.enable_autoscaling ? var.user_node_max_count : var.user_node_count
  }

  # No taint - accepts all workloads
  labels = {
    "node-role" = "user"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-user-node"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]
}
