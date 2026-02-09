# EKS Kong Konnect Cloud Gateway - CloudFront Distribution Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudformation_stack.cloudfront.outputs["DistributionId"]
}

output "distribution_arn" {
  description = "CloudFront distribution ARN"
  value       = aws_cloudformation_stack.cloudfront.outputs["DistributionArn"]
}

output "distribution_domain_name" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudformation_stack.cloudfront.outputs["DistributionDomainName"]
}

output "distribution_hosted_zone_id" {
  description = "CloudFront distribution Route53 hosted zone ID"
  value       = aws_cloudformation_stack.cloudfront.outputs["DistributionHostedZoneId"]
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : null
}

output "waf_web_acl_id" {
  description = "WAF Web ACL ID"
  value       = var.enable_waf ? aws_wafv2_web_acl.main[0].id : null
}

output "oac_id" {
  description = "Origin Access Control ID for S3"
  value       = var.enable_s3_origin ? aws_cloudfront_origin_access_control.s3[0].id : null
}
