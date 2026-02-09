# MunchGo Microservices - S3 SPA Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "force_destroy" {
  description = "Allow bucket deletion even if not empty (true for dev)"
  type        = bool
  default     = true
}

variable "enable_versioning" {
  description = "Enable S3 versioning for SPA assets"
  type        = bool
  default     = false
}

variable "cors_allowed_origins" {
  description = "Allowed origins for CORS (e.g., CloudFront domain)"
  type        = list(string)
  default     = ["*"]
}

variable "cloudfront_distribution_arn" {
  description = "CloudFront distribution ARN for OAC bucket policy. Pass empty string if CloudFront not yet created."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
