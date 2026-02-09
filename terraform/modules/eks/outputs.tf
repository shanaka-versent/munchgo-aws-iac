# EKS Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  description = "EKS cluster CA certificate"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.main.arn
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL"
  value       = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

output "node_role_arn" {
  description = "IAM role ARN for node groups"
  value       = aws_iam_role.node.arn
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID (auto-created by EKS)"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
