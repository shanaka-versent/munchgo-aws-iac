# EKS Kong Konnect Cloud Gateway - AWS Load Balancer Controller Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "release_name" {
  description = "AWS Load Balancer Controller Helm release name"
  value       = helm_release.aws_load_balancer_controller.name
}

output "namespace" {
  description = "AWS Load Balancer Controller namespace"
  value       = helm_release.aws_load_balancer_controller.namespace
}
