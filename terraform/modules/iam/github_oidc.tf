# GitHub Actions OIDC Provider + SPA Deploy Role
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Enables GitHub Actions to assume IAM roles via OIDC federation.
# No long-lived AWS credentials are stored in GitHub — instead, GitHub's
# OIDC token is exchanged for short-lived AWS session credentials.
#
# The SPA deploy role grants:
# - S3: PutObject, DeleteObject, ListBucket on the SPA bucket
# - CloudFront: CreateInvalidation on the distribution
#
# Trust policy restricts access to specific GitHub repos.

# ==============================================================================
# GITHUB ACTIONS OIDC PROVIDER
# ==============================================================================
# One per AWS account. If this already exists (e.g., from another Terraform
# workspace), set enable_github_oidc = false and pass the existing ARN
# via github_oidc_provider_arn variable.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-github-oidc"
  })
}

locals {
  github_oidc_provider_arn = var.enable_github_oidc ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn
}

# ==============================================================================
# SPA DEPLOY ROLE
# ==============================================================================
# Assumed by GitHub Actions in the munchgo-spa repo to deploy to S3
# and invalidate CloudFront.

resource "aws_iam_role" "spa_deploy" {
  count = var.enable_spa_deploy_role ? 1 : 0
  name  = "role-spa-deploy-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = local.github_oidc_provider_arn
      }
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = flatten([
            for repo in var.spa_deploy_github_repos : [
              "repo:${repo}:ref:refs/heads/main",
              "repo:${repo}:environment:production"
            ]
          ])
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_policy" "spa_deploy" {
  count       = var.enable_spa_deploy_role ? 1 : 0
  name        = "policy-spa-deploy-${var.name_prefix}"
  description = "IAM policy for SPA GitHub Actions deploy — S3 sync + CloudFront invalidation"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Deploy"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-munchgo-spa-*",
          "arn:aws:s3:::${var.name_prefix}-munchgo-spa-*/*"
        ]
      },
      {
        Sid    = "CloudFrontInvalidation"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation",
          "cloudfront:GetInvalidation",
          "cloudfront:ListInvalidations"
        ]
        Resource = "arn:aws:cloudfront::*:distribution/*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "spa_deploy" {
  count      = var.enable_spa_deploy_role ? 1 : 0
  policy_arn = aws_iam_policy.spa_deploy[0].arn
  role       = aws_iam_role.spa_deploy[0].name
}
