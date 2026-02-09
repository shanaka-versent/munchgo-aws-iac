# MunchGo Microservices - S3 SPA Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "bucket_id" {
  description = "S3 bucket ID"
  value       = aws_s3_bucket.spa.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.spa.arn
}

output "bucket_regional_domain_name" {
  description = "S3 bucket regional domain name (for CloudFront origin)"
  value       = aws_s3_bucket.spa.bucket_regional_domain_name
}

output "bucket_domain_name" {
  description = "S3 bucket domain name"
  value       = aws_s3_bucket.spa.bucket_domain_name
}
