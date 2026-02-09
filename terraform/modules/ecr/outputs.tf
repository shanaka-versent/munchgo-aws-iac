# MunchGo Microservices - ECR Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "repository_urls" {
  description = "Map of service name to ECR repository URL"
  value       = { for k, v in aws_ecr_repository.munchgo : k => v.repository_url }
}

output "registry_id" {
  description = "ECR registry ID (AWS account ID)"
  value       = values(aws_ecr_repository.munchgo)[0].registry_id
}

output "repository_arns" {
  description = "Map of service name to ECR repository ARN"
  value       = { for k, v in aws_ecr_repository.munchgo : k => v.arn }
}
