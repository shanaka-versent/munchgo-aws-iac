# EKS Kong Konnect Cloud Gateway - IAM Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM role ARN"
  value       = aws_iam_role.lb_controller.arn
}

output "lb_controller_policy_arn" {
  description = "AWS Load Balancer Controller IAM policy ARN"
  value       = aws_iam_policy.lb_controller.arn
}

output "external_secrets_role_arn" {
  description = "External Secrets Operator IAM role ARN (for IRSA)"
  value       = var.enable_external_secrets ? aws_iam_role.external_secrets[0].arn : ""
}

output "cognito_auth_service_role_arn" {
  description = "Cognito auth-service IAM role ARN (for IRSA)"
  value       = var.enable_cognito ? aws_iam_role.cognito_auth_service[0].arn : ""
}

output "spa_deploy_role_arn" {
  description = "SPA deploy IAM role ARN (for GitHub Actions OIDC)"
  value       = var.enable_spa_deploy_role ? aws_iam_role.spa_deploy[0].arn : ""
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = var.enable_github_oidc ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn
}
