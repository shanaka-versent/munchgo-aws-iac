# ArgoCD Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "release_name" {
  description = "ArgoCD Helm release name"
  value       = helm_release.argocd.name
}

output "admin_password" {
  description = "ArgoCD admin password"
  value       = data.kubernetes_secret.argocd_admin.data["password"]
  sensitive   = true
}
