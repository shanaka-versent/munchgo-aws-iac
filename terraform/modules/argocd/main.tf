# ArgoCD Module
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Installs ArgoCD via Helm and bootstraps the root application
# using the argocd-apps chart (App of Apps pattern).
# After terraform apply, ArgoCD automatically syncs all child apps
# from the Git repository — no manual kubectl step needed.

locals {
  tolerations = [{
    key      = "CriticalAddonsOnly"
    operator = "Exists"
    effect   = "NoSchedule"
  }]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      server = {
        service = {
          type = var.service_type
        }
        extraArgs   = var.insecure_mode ? ["--insecure"] : []
        tolerations = local.tolerations
      }
      configs = {
        params = {
          "server.insecure" = var.insecure_mode
        }
      }
      controller = {
        tolerations = local.tolerations
      }
      repoServer = {
        tolerations = local.tolerations
      }
      applicationSet = {
        tolerations = local.tolerations
      }
      notifications = {
        tolerations = local.tolerations
      }
      redis = {
        tolerations = local.tolerations
      }
      dex = {
        tolerations = local.tolerations
      }
    })
  ]

  depends_on = [var.cluster_dependency]
}

# Bootstrap the root application (App of Apps pattern)
# This tells ArgoCD to watch the Git repo and deploy all child apps
# via sync waves. Eliminates the manual "kubectl apply root-app.yaml" step.
resource "helm_release" "argocd_root_app" {
  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "1.6.2"
  namespace  = "argocd"
  wait       = false

  values = [
    yamlencode({
      applications = [{
        name       = "cloud-gateway-root"
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        project    = "default"
        source = {
          repoURL        = var.git_repo_url
          targetRevision = "HEAD"
          path           = "argocd/apps"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = [
            "CreateNamespace=true",
            "ApplyOutOfSyncOnly=true"
          ]
        }
      }]
    })
  ]

  depends_on = [helm_release.argocd]
}

# Get ArgoCD admin password
data "kubernetes_secret" "argocd_admin" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }

  depends_on = [helm_release.argocd]
}
