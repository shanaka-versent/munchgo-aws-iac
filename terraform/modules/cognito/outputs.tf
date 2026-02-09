# MunchGo Authentication - Cognito Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.munchgo.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.munchgo.arn
}

output "user_pool_endpoint" {
  description = "Cognito User Pool endpoint (for OIDC discovery)"
  value       = aws_cognito_user_pool.munchgo.endpoint
}

output "app_client_id" {
  description = "Cognito App Client ID"
  value       = aws_cognito_user_pool_client.munchgo_app.id
}

output "domain" {
  description = "Cognito User Pool domain URL"
  value       = "https://${aws_cognito_user_pool_domain.munchgo.domain}.auth.${var.region}.amazoncognito.com"
}

output "issuer_url" {
  description = "OIDC issuer URL (for Kong openid-connect plugin)"
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.munchgo.id}"
}

output "jwks_uri" {
  description = "JWKS URI for token signature verification"
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.munchgo.id}/.well-known/jwks.json"
}

output "cognito_secret_name" {
  description = "Secrets Manager secret name for Cognito config"
  value       = aws_secretsmanager_secret.cognito_config.name
}

output "cognito_secret_arn" {
  description = "Secrets Manager secret ARN for Cognito config"
  value       = aws_secretsmanager_secret.cognito_config.arn
  sensitive   = true
}
