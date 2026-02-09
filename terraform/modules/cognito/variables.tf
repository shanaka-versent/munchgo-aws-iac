# MunchGo Authentication - Cognito Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names (e.g., kong-gw-poc)"
  type        = string
}

variable "region" {
  description = "AWS region for Cognito User Pool"
  type        = string
  default     = "ap-southeast-2"
}

variable "user_pool_groups" {
  description = "Cognito User Pool groups (mapped to MunchGo roles)"
  type        = list(string)
  default = [
    "ROLE_CUSTOMER",
    "ROLE_RESTAURANT_OWNER",
    "ROLE_COURIER",
    "ROLE_ADMIN",
  ]
}

variable "callback_urls" {
  description = "OAuth2 callback URLs for app client (empty = no OAuth flows, admin API only)"
  type        = list(string)
  default     = []
}

variable "logout_urls" {
  description = "OAuth2 logout URLs for app client"
  type        = list(string)
  default     = []
}

variable "enable_mfa" {
  description = "Enable Multi-Factor Authentication (recommended for production)"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable deletion protection on User Pool (recommended for production)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
