# MunchGo Microservices - ECR Repositories
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# LAYER 1: Cloud Foundations
# Creates ECR repositories for all MunchGo microservice container images.
# GitHub Actions CI pipelines (in munchgo-microservices repo) push images here.
# ArgoCD deploys from these registries via the munchgo-k8s-config GitOps repo.

locals {
  services = [
    "munchgo-auth-service",
    "munchgo-consumer-service",
    "munchgo-restaurant-service",
    "munchgo-courier-service",
    "munchgo-order-service",
    "munchgo-order-saga-orchestrator",
  ]
}

resource "aws_ecr_repository" "munchgo" {
  for_each = toset(local.services)

  name                 = each.value
  image_tag_mutability = "MUTABLE" # Allow :latest tag updates from CI

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name    = each.value
    Layer   = "Layer1-CloudFoundations"
    Module  = "ecr"
    Service = each.value
  })
}

# Lifecycle policy: keep last 20 tagged images, expire untagged after 7 days
resource "aws_ecr_lifecycle_policy" "munchgo" {
  for_each = aws_ecr_repository.munchgo

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
