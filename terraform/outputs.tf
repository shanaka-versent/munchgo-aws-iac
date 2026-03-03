# EKS Kong Konnect Cloud Gateway - Terraform Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

# VPC Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr
}

# EKS Outputs
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_get_credentials_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

# ArgoCD Outputs
output "argocd_admin_password" {
  description = "ArgoCD admin password"
  value       = module.argocd.admin_password
  sensitive   = true
}

output "argocd_port_forward_command" {
  description = "Command to access ArgoCD UI"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

# LB Controller
output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM role ARN"
  value       = module.iam.lb_controller_role_arn
}

# ==============================================================================
# TRANSIT GATEWAY OUTPUTS
# Use these values when configuring Kong Cloud Gateway in Konnect
# ==============================================================================

output "transit_gateway_id" {
  description = "Transit Gateway ID — provide to Konnect when attaching Cloud Gateway network"
  value       = aws_ec2_transit_gateway.kong.id
}

output "transit_gateway_arn" {
  description = "Transit Gateway ARN"
  value       = aws_ec2_transit_gateway.kong.arn
}

output "ram_share_arn" {
  description = "RAM Resource Share ARN — provide to Konnect for Transit Gateway attachment"
  value       = aws_ram_resource_share.kong_tgw.arn
}

# ==============================================================================
# CLOUDFRONT OUTPUTS (conditional)
# ==============================================================================

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_id : null
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_domain_name : null
}

output "cloudfront_url" {
  description = "CloudFront URL"
  value       = var.enable_cloudfront ? "https://${module.cloudfront[0].distribution_domain_name}" : null
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = var.enable_cloudfront ? module.cloudfront[0].waf_web_acl_arn : null
}

output "application_url" {
  description = "Application URL (CloudFront if enabled, otherwise Kong Cloud Gateway proxy URL)"
  value       = var.enable_cloudfront ? "https://${module.cloudfront[0].distribution_domain_name}" : "https://${var.kong_cloud_gateway_domain}"
}

# ==============================================================================
# MUNCHGO DATA INFRASTRUCTURE OUTPUTS
# ==============================================================================

# ECR
output "ecr_repository_urls" {
  description = "Map of MunchGo service name to ECR repository URL"
  value       = var.enable_ecr ? module.ecr[0].repository_urls : {}
}

# MSK
output "msk_bootstrap_brokers" {
  description = "MSK plaintext bootstrap broker connection string"
  value       = var.enable_msk ? module.msk[0].bootstrap_brokers : null
}

output "msk_bootstrap_brokers_tls" {
  description = "MSK TLS bootstrap broker connection string"
  value       = var.enable_msk ? module.msk[0].bootstrap_brokers_tls : null
}

output "msk_zookeeper_connect" {
  description = "MSK ZooKeeper connection string"
  value       = var.enable_msk ? module.msk[0].zookeeper_connect_string : null
}

# RDS
output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = var.enable_rds ? module.rds[0].endpoint : null
}

output "rds_master_secret_arn" {
  description = "RDS master credentials Secrets Manager ARN"
  value       = var.enable_rds ? module.rds[0].master_secret_arn : null
  sensitive   = true
}

output "rds_master_secret_name" {
  description = "RDS master credentials Secrets Manager name"
  value       = var.enable_rds ? module.rds[0].master_secret_name : null
}

output "rds_auth_db_secret_name" {
  value = var.enable_rds ? module.rds[0].service_secret_names["auth"] : null
}

output "rds_consumers_db_secret_name" {
  value = var.enable_rds ? module.rds[0].service_secret_names["consumers"] : null
}

output "rds_restaurants_db_secret_name" {
  value = var.enable_rds ? module.rds[0].service_secret_names["restaurants"] : null
}

output "rds_couriers_db_secret_name" {
  value = var.enable_rds ? module.rds[0].service_secret_names["couriers"] : null
}

output "rds_orders_db_secret_name" {
  value = var.enable_rds ? module.rds[0].service_secret_names["orders"] : null
}

output "rds_sagas_db_secret_name" {
  value = var.enable_rds ? module.rds[0].service_secret_names["sagas"] : null
}

# S3 SPA
output "spa_bucket_name" {
  description = "S3 SPA bucket name"
  value       = var.enable_spa ? module.spa[0].bucket_id : null
}

output "spa_bucket_domain" {
  description = "S3 SPA bucket regional domain name"
  value       = var.enable_spa ? module.spa[0].bucket_regional_domain_name : null
}

# External Secrets
output "external_secrets_role_arn" {
  description = "External Secrets Operator IRSA role ARN"
  value       = var.enable_external_secrets ? module.iam.external_secrets_role_arn : null
}

# Cognito
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = var.enable_cognito ? module.cognito[0].user_pool_id : null
}

output "cognito_app_client_id" {
  description = "Cognito App Client ID"
  value       = var.enable_cognito ? module.cognito[0].app_client_id : null
}

output "cognito_issuer_url" {
  description = "Cognito OIDC issuer URL (for Kong openid-connect plugin)"
  value       = var.enable_cognito ? module.cognito[0].issuer_url : null
}

output "cognito_domain" {
  description = "Cognito User Pool domain URL"
  value       = var.enable_cognito ? module.cognito[0].domain : null
}

output "cognito_secret_name" {
  description = "Secrets Manager secret name for Cognito config (update External Secrets with this value)"
  value       = var.enable_cognito ? module.cognito[0].cognito_secret_name : null
}

output "cognito_auth_service_role_arn" {
  description = "Cognito auth-service IRSA role ARN (annotate K8s service account with this)"
  value       = var.enable_cognito ? module.iam.cognito_auth_service_role_arn : null
}

# GitHub Actions OIDC
output "spa_deploy_role_arn" {
  description = "SPA deploy IAM role ARN — configure as AWS_ROLE_ARN secret in munchgo-spa GitHub repo"
  value       = module.iam.spa_deploy_role_arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = module.iam.github_oidc_provider_arn
}

# ==============================================================================
# KONG KONNECT (Terraform IaC)
# ==============================================================================

output "konnect_control_plane_id" {
  description = "Kong Konnect Control Plane ID (auto-read by 03-post-terraform-setup.sh)"
  value       = length(konnect_gateway_control_plane.munchgo) > 0 ? konnect_gateway_control_plane.munchgo[0].id : ""
}

output "konnect_network_id" {
  description = "Kong Cloud Gateway Network ID"
  value       = length(konnect_cloud_gateway_network.munchgo) > 0 ? konnect_cloud_gateway_network.munchgo[0].id : ""
}

output "kong_cloud_gateway_setup_command" {
  description = "Kong Konnect is fully managed by Terraform (konnect.tf) in a single terraform apply."
  value       = <<-EOT
    # All Konnect resources are created in a single 'terraform apply':
    #   1. konnect_gateway_control_plane.munchgo    — instant
    #   2. konnect_cloud_gateway_network.munchgo    — instant (but waits ~30 min to reach 'ready')
    #   3. null_resource.wait_for_network_ready      — polls API every 30s until ready
    #   4. konnect_cloud_gateway_configuration.munchgo
    #   5. konnect_cloud_gateway_transit_gateway.eks — runs after network is ready
    #
    # Control Plane ID: ${length(konnect_gateway_control_plane.munchgo) > 0 ? konnect_gateway_control_plane.munchgo[0].id : "not yet created"}
    # Transit Gateway:  ${aws_ec2_transit_gateway.kong.id}
    # RAM Share:        ${aws_ram_resource_share.kong_tgw.arn}
  EOT
}
