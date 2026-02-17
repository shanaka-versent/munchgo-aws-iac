# EKS Kong Konnect Cloud Gateway - IAM Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA role federation"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL without https:// for trust policy conditions"
  type        = string
}

variable "enable_external_secrets" {
  description = "Enable External Secrets Operator IRSA role"
  type        = bool
  default     = true
}

variable "enable_cognito" {
  description = "Enable Cognito auth-service IRSA role"
  type        = bool
  default     = true
}

variable "enable_github_oidc" {
  description = "Create GitHub Actions OIDC provider (set false if one already exists in the account)"
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN (only used when enable_github_oidc = false)"
  type        = string
  default     = ""
}

variable "enable_spa_deploy_role" {
  description = "Enable SPA deploy IAM role for GitHub Actions"
  type        = bool
  default     = true
}

variable "spa_deploy_github_repos" {
  description = "GitHub repos allowed to assume the CI/CD deploy role (org/repo format)"
  type        = list(string)
  default     = ["shanaka-versent/munchgo-spa", "shanaka-versent/munchgo-microservices"]
}

variable "aws_account_id" {
  description = "AWS account ID for ECR policy resource ARNs"
  type        = string
  default     = ""
}

variable "ecr_region" {
  description = "AWS region for ECR repositories"
  type        = string
  default     = "ap-southeast-2"
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
