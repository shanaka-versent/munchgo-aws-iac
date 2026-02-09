# MunchGo Microservices - S3 SPA Hosting
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# LAYER 1: Cloud Foundations
# S3 bucket for MunchGo React Single Page Application.
# Served exclusively via CloudFront with Origin Access Control (OAC).
# No public access — all requests must come through CloudFront.
#
# CloudFront routing:
#   /          → S3 (React SPA index.html)
#   /static/*  → S3 (hashed assets, long cache TTL)
#   /api/*     → Kong Cloud Gateway (API requests, no cache)
#
# SPA routing: All non-API 404s return index.html (React Router handles client-side routing)

# ==============================================================================
# S3 BUCKET
# ==============================================================================

resource "aws_s3_bucket" "spa" {
  bucket_prefix = "${var.name_prefix}-munchgo-spa-"
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-spa"
    Layer  = "Layer1-CloudFoundations"
    Module = "spa"
  })
}

# Block all public access — CloudFront OAC is the only entry point
resource "aws_s3_bucket_public_access_block" "spa" {
  bucket = aws_s3_bucket.spa.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning for rollback capability
resource "aws_s3_bucket_versioning" "spa" {
  bucket = aws_s3_bucket.spa.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# CORS configuration for SPA assets
resource "aws_s3_bucket_cors_configuration" "spa" {
  bucket = aws_s3_bucket.spa.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# Bucket policy: Allow CloudFront OAC access only
resource "aws_s3_bucket_policy" "spa" {
  bucket = aws_s3_bucket.spa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.spa.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = var.cloudfront_distribution_arn
          }
        }
      }
    ]
  })
}

# Server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "spa" {
  bucket = aws_s3_bucket.spa.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
