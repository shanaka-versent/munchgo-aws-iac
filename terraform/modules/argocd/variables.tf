# ArgoCD Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "argocd_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "5.51.6"
}

variable "service_type" {
  description = "ArgoCD server service type"
  type        = string
  default     = "ClusterIP"
}

variable "insecure_mode" {
  description = "Run ArgoCD in insecure mode (no TLS)"
  type        = bool
  default     = true
}

variable "cluster_dependency" {
  description = "Cluster dependency for ordering"
  type        = string
}

variable "git_repo_url" {
  description = "Git repository URL for ArgoCD root app (App of Apps)"
  type        = string
}
