# EKS Kong Konnect Cloud Gateway - Terraform Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

# AWS Region
variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "poc"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "kong-gw"
}

# Network
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones"
  type        = number
  default     = 2
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets"
  type        = bool
  default     = true
}

# EKS Configuration
variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "eks_node_count" {
  description = "Number of EKS system nodes"
  type        = number
  default     = 2
}

variable "eks_node_instance_type" {
  description = "Instance type for EKS system nodes"
  type        = string
  default     = "t3.medium"
}

# User Node Pool (optional)
variable "enable_user_node_pool" {
  description = "Enable separate user node pool"
  type        = bool
  default     = true
}

variable "user_node_count" {
  description = "Number of user nodes"
  type        = number
  default     = 2
}

variable "user_node_instance_type" {
  description = "Instance type for user nodes"
  type        = string
  default     = "t3.medium"
}

# EKS Autoscaling
variable "enable_eks_autoscaling" {
  description = "Enable EKS cluster autoscaler"
  type        = bool
  default     = false
}

variable "system_node_min_count" {
  description = "Minimum number of system nodes (when autoscaling enabled)"
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "Maximum number of system nodes (when autoscaling enabled)"
  type        = number
  default     = 3
}

variable "user_node_min_count" {
  description = "Minimum number of user nodes (when autoscaling enabled)"
  type        = number
  default     = 1
}

variable "user_node_max_count" {
  description = "Maximum number of user nodes (when autoscaling enabled)"
  type        = number
  default     = 5
}

# EKS Logging
variable "enable_logging" {
  description = "Enable EKS control plane logging"
  type        = bool
  default     = false
}

# ==============================================================================
# MUNCHGO DATA INFRASTRUCTURE
# ==============================================================================

# ECR - Container image repositories
variable "enable_ecr" {
  description = "Enable ECR repositories for MunchGo microservices"
  type        = bool
  default     = true
}

# MSK - Kafka event messaging
variable "enable_msk" {
  description = "Enable Amazon MSK for MunchGo event-driven messaging"
  type        = bool
  default     = true
}

variable "msk_instance_type" {
  description = "MSK broker instance type"
  type        = string
  default     = "kafka.m5.large"
}

variable "msk_broker_count" {
  description = "Number of MSK broker nodes"
  type        = number
  default     = 2
}

variable "msk_ebs_volume_size" {
  description = "MSK EBS volume size per broker (GB)"
  type        = number
  default     = 100
}

# RDS PostgreSQL - shared instance with 6 databases
variable "enable_rds" {
  description = "Enable RDS PostgreSQL for MunchGo microservice databases"
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "rds_allocated_storage" {
  description = "RDS initial allocated storage (GB)"
  type        = number
  default     = 20
}

variable "rds_multi_az" {
  description = "Enable RDS Multi-AZ deployment"
  type        = bool
  default     = false
}

# S3 SPA - React frontend hosting
variable "enable_spa" {
  description = "Enable S3 bucket for MunchGo React SPA hosting via CloudFront"
  type        = bool
  default     = true
}

# External Secrets Operator
variable "enable_external_secrets" {
  description = "Enable External Secrets Operator IRSA role for Secrets Manager access"
  type        = bool
  default     = true
}

# ==============================================================================
# COGNITO AUTHENTICATION
# ==============================================================================
# Amazon Cognito User Pool for MunchGo end-user authentication.
# Replaces the custom JWT implementation with a managed identity provider.
# Kong Cloud Gateway validates Cognito tokens via the openid-connect plugin.

variable "enable_cognito" {
  description = "Enable Amazon Cognito User Pool for MunchGo authentication"
  type        = bool
  default     = true
}

variable "cognito_callback_urls" {
  description = "OAuth2 callback URLs for Cognito app client (e.g., SPA redirect URIs)"
  type        = list(string)
  default     = []
}

variable "cognito_logout_urls" {
  description = "OAuth2 logout URLs for Cognito app client"
  type        = list(string)
  default     = []
}

variable "cognito_enable_mfa" {
  description = "Enable Multi-Factor Authentication on Cognito User Pool"
  type        = bool
  default     = false
}

variable "cognito_deletion_protection" {
  description = "Enable deletion protection on Cognito User Pool (recommended for production)"
  type        = bool
  default     = false
}

# ==============================================================================
# CLOUDFRONT + WAF (Edge Security Layer)
# ==============================================================================
# CloudFront + WAF sits in front of Kong Cloud Gateway's public proxy URL.
# WAF is mandatory for production — it provides DDoS protection, SQLi/XSS
# filtering, rate limiting, and geo-blocking. CloudFront also enforces origin
# mTLS to prevent direct access to Kong Cloud Gateway, ensuring all traffic
# passes through WAF inspection.
#
# CloudFront bypass prevention (two layers):
# 1. Origin mTLS (strongest): CloudFront presents client cert to Kong origin
# 2. Custom origin header: Kong pre-function validates X-CF-Secret header
# Either or both can be enabled. mTLS alone is sufficient for bypass prevention.

variable "enable_cloudfront" {
  description = "Enable CloudFront + WAF in front of Kong Cloud Gateway (required for production)"
  type        = bool
  default     = true
}

variable "kong_cloud_gateway_domain" {
  description = "Kong Cloud Gateway proxy domain (e.g., <prefix>.au.kong-cloud.com). Required for CloudFront origin."
  type        = string
  default     = ""
}

# CloudFront bypass prevention — Layer 1: Origin mTLS (recommended)
variable "origin_mtls_certificate_arn" {
  description = "ACM certificate ARN for CloudFront origin mTLS (must be in us-east-1, with EKU=clientAuth). Empty = disabled."
  type        = string
  default     = ""
}

# CloudFront bypass prevention — Layer 2: Custom origin header
variable "cf_origin_header_name" {
  description = "Custom header name for CloudFront bypass prevention"
  type        = string
  default     = "X-CF-Secret"
}

variable "cf_origin_header_value" {
  description = "Secret value for the custom origin header. Empty = disabled. Must match Kong pre-function plugin."
  type        = string
  default     = ""
  sensitive   = true
}

# WAF
variable "enable_waf" {
  description = "Enable WAF Web ACL on CloudFront distribution"
  type        = bool
  default     = true
}

variable "enable_waf_rate_limiting" {
  description = "Enable WAF rate limiting rule"
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "WAF rate limit (requests per 5 minutes per IP)"
  type        = number
  default     = 2000
}

# CloudFront configuration
variable "cloudfront_price_class" {
  description = "CloudFront price class"
  type        = string
  default     = "PriceClass_100"
}

variable "cloudfront_certificate_arn" {
  description = "ACM certificate ARN for CloudFront custom domain (must be in us-east-1)"
  type        = string
  default     = ""
}

variable "cloudfront_custom_domain" {
  description = "Custom domain for CloudFront distribution"
  type        = string
  default     = ""
}

# ArgoCD Configuration
variable "argocd_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "5.51.6"
}

variable "argocd_service_type" {
  description = "ArgoCD server service type (LoadBalancer or ClusterIP)"
  type        = string
  default     = "ClusterIP"
}

variable "argocd_git_repo_url" {
  description = "Git repository URL for ArgoCD root app (App of Apps pattern)"
  type        = string
  default     = "https://github.com/shanaka-versent/munchgo-aws-iac.git"
}

# Kong Cloud Gateway CIDR (default: 192.168.0.0/16)
# This is the CIDR block used by Kong's Dedicated Cloud Gateway network.
# Must not overlap with your VPC CIDR.
variable "kong_cloud_gateway_cidr" {
  description = "CIDR block of Kong Cloud Gateway network (for Transit Gateway routing)"
  type        = string
  default     = "192.168.0.0/16"
}

# Tags
variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default = {
    Project   = "MunchGo-AWS-IaC"
    Purpose   = "MunchGo-Modernization"
    ManagedBy = "Terraform"
  }
}
