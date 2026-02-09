# EKS Kong Konnect Cloud Gateway - AWS Load Balancer Controller Module
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Layer 2: Base EKS Cluster Setup - AWS Load Balancer Controller
# Installed via Terraform as part of the base cluster setup.
#
# The LB Controller provides:
# - TargetGroupBinding CRD for registering Kong pods with Terraform-managed NLB
# - NLB/ALB lifecycle management from Kubernetes Service annotations
#
# In this architecture, the LB Controller is used primarily for the
# TargetGroupBinding CRD, NOT for creating the NLB (which is Terraform-managed).

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_version

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.iam_role_arn
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  wait    = true
  timeout = 300

  depends_on = [var.cluster_dependency]
}
