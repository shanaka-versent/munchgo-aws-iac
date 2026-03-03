# EKS Kong Konnect Cloud Gateway - Terraform Providers
# @author Shanaka Jayasundera - shanakaj@gmail.com

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.82" # Required for CloudFront origin mTLS support
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    konnect = {
      source  = "kong/konnect"
      version = "~> 2.3"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

# US-East-1 provider required for:
# - CloudFront WAF Web ACL (must be in us-east-1)
# - Origin mTLS client certificate (ACM cert must be in us-east-1)
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

# Kubernetes provider - configured after EKS cluster is created
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
  }
}

# Kong Konnect provider
# Token comes from var.konnect_token (set via TF_VAR_konnect_token or terraform.tfvars).
# Only used when konnect_token is provided — Konnect resources are skipped if empty.
provider "konnect" {
  personal_access_token = var.konnect_token
  server_url            = "https://global.api.konghq.com"
}

# Helm provider - configured after EKS cluster is created
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
    }
  }
}
