# EKS Kong Konnect Cloud Gateway - CloudFront Distribution with WAF
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# LAYER 2: Edge Security (Terraform)
#
# This module creates a CloudFront distribution with:
# - WAF Web ACL with AWS Managed Rules (SQLi, XSS, Bad Inputs, Rate Limiting)
# - Security response headers (HSTS, X-Frame-Options, X-Content-Type-Options)
# - CloudFront bypass prevention via mTLS and/or custom origin header
# - Optional S3 origin for static assets with Origin Access Control (OAC)
#
# Architecture:
# Client --> CloudFront (WAF) --> Kong Cloud Gateway NLB (Kong's VPC) --> Kong DP --> Transit GW --> EKS
#
# CloudFront Bypass Prevention (two layers, either or both):
#
# 1. Origin mTLS (recommended, strongest):
#    CloudFront presents a client certificate during TLS handshake with Kong's
#    origin. Kong Cloud Gateway validates the certificate and rejects connections
#    without it. This is cryptographic proof of CloudFront's identity.
#    Requires: ACM-imported certificate in us-east-1 with clientAuth EKU.
#    Launched: AWS CloudFront origin mTLS (January 2026).
#
# 2. Custom origin header (application-layer fallback):
#    CloudFront injects X-CF-Secret on every request. A Kong pre-function plugin
#    validates the header and rejects direct-to-origin requests.
#
# Security model:
# 1. WAF filters malicious traffic at the edge
# 2. Origin mTLS provides cryptographic bypass prevention
# 3. Custom origin header provides application-layer bypass prevention
# 4. Kong plugins provide API security (JWT, rate-limiting, CORS)
# 5. Transit Gateway provides private connectivity to backend services

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.82" # Required for origin mTLS support
      configuration_aliases = [aws.us_east_1]
    }
  }
}

# ==============================================================================
# WAF WEB ACL
# ==============================================================================

resource "aws_wafv2_web_acl" "main" {
  count    = var.enable_waf ? 1 : 0
  name     = "${var.name_prefix}-waf-acl"
  scope    = "CLOUDFRONT"
  provider = aws.us_east_1 # WAF for CloudFront must be in us-east-1

  default_action {
    allow {}
  }

  # AWS Managed Rules - Common Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules - Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules - SQL Injection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-sqli"
      sampled_requests_enabled   = true
    }
  }

  # Rate limiting rule (dynamic - only created if enabled)
  dynamic "rule" {
    for_each = var.enable_rate_limiting ? [1] : []
    content {
      name     = "RateLimitRule"
      priority = 10

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = var.rate_limit
          aggregate_key_type = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name_prefix}-rate-limit"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-waf-acl"
    Layer  = "Layer2-EdgeSecurity"
    Module = "cloudfront"
  })
}

# ==============================================================================
# CLOUDFRONT ORIGIN ACCESS CONTROL (for S3 static assets)
# ==============================================================================

resource "aws_cloudfront_origin_access_control" "s3" {
  count                             = var.enable_s3_origin ? 1 : 0
  name                              = "${var.name_prefix}-s3-oac"
  description                       = "OAC for S3 static assets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ==============================================================================
# CLOUDFRONT CACHE POLICIES
# ==============================================================================

# Cache policy for static assets (aggressive caching)
resource "aws_cloudfront_cache_policy" "static_assets" {
  count   = var.enable_s3_origin ? 1 : 0
  name    = "${var.name_prefix}-static-cache"
  comment = "Cache policy for static assets (CSS, JS, images)"

  default_ttl = 86400    # 1 day
  max_ttl     = 31536000 # 1 year
  min_ttl     = 1

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

# Use AWS managed CachingDisabled policy for API traffic (no caching)
# Managed policy ID: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# ==============================================================================
# CLOUDFRONT ORIGIN REQUEST POLICY
# ==============================================================================

# Use AWS managed AllViewerExceptHostHeader policy
# Forwards all viewer headers (including Authorization) except Host
# Managed policy ID: b689b0a0-8776-4c4d-943d-2588d6b6e5b8
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# ==============================================================================
# CLOUDFRONT RESPONSE HEADERS POLICY
# ==============================================================================

resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name    = "${var.name_prefix}-security-headers"
  comment = "Security headers policy for Kong Cloud Gateway POC"

  security_headers_config {
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
      preload                    = true
    }
    xss_protection {
      mode_block = true
      override   = true
      protection = true
    }
  }

  custom_headers_config {
    items {
      header   = "X-Served-By"
      override = true
      value    = "CloudFront-${var.name_prefix}"
    }
  }
}

# ==============================================================================
# CLOUDFRONT DISTRIBUTION (via CloudFormation)
# ==============================================================================
# The Terraform AWS provider does not yet support OriginMtlsConfig for
# CloudFront distributions (as of v6.31). AWS CloudFormation DOES support it,
# so we wrap the distribution in an aws_cloudformation_stack resource.
#
# All other resources (WAF, OAC, cache policies, response headers) remain
# native Terraform resources and are passed into the stack as parameters.

resource "aws_cloudformation_stack" "cloudfront" {
  name = "${var.name_prefix}-cloudfront-dist"

  parameters = {
    Comment                    = "${var.name_prefix} - CloudFront WAF - Kong Cloud Gateway"
    PriceClass                 = var.price_class
    WebACLArn                  = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : ""
    Aliases                    = var.custom_domain
    KongDomainName             = var.kong_cloud_gateway_domain
    OriginMtlsCertificateArn   = var.origin_mtls_certificate_arn
    CfOriginHeaderName         = var.cf_origin_header_name
    CfOriginHeaderValue        = var.cf_origin_header_value
    CachePolicyId              = data.aws_cloudfront_cache_policy.caching_disabled.id
    OriginRequestPolicyId      = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    ResponseHeadersPolicyId    = aws_cloudfront_response_headers_policy.security_headers.id
    AcmCertificateArn          = var.acm_certificate_arn
    EnableS3Origin             = var.enable_s3_origin ? "true" : "false"
    S3BucketDomainName         = var.s3_bucket_regional_domain_name
    S3OACId                    = var.enable_s3_origin ? aws_cloudfront_origin_access_control.s3[0].id : ""
    S3CachePolicyId            = var.enable_s3_origin ? aws_cloudfront_cache_policy.static_assets[0].id : ""
    GeoRestrictionType         = var.geo_restriction_type
    GeoRestrictionLocations    = join(",", var.geo_restriction_locations)
  }

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-cloudfront"
    Layer  = "Layer2-EdgeSecurity"
    Module = "cloudfront"
  })

  template_body = <<-TEMPLATE
  AWSTemplateFormatVersion: "2010-09-09"
  Description: "CloudFront distribution with origin mTLS support for Kong Cloud Gateway"

  Parameters:
    Comment:
      Type: String
    PriceClass:
      Type: String
    WebACLArn:
      Type: String
      Default: ""
    Aliases:
      Type: String
      Default: ""
    KongDomainName:
      Type: String
    OriginMtlsCertificateArn:
      Type: String
      Default: ""
    CfOriginHeaderName:
      Type: String
      Default: "X-CF-Secret"
    CfOriginHeaderValue:
      Type: String
      Default: ""
      NoEcho: true
    CachePolicyId:
      Type: String
    OriginRequestPolicyId:
      Type: String
    ResponseHeadersPolicyId:
      Type: String
    AcmCertificateArn:
      Type: String
      Default: ""
    EnableS3Origin:
      Type: String
      Default: "false"
      AllowedValues: ["true", "false"]
    S3BucketDomainName:
      Type: String
      Default: ""
    S3OACId:
      Type: String
      Default: ""
    S3CachePolicyId:
      Type: String
      Default: ""
    GeoRestrictionType:
      Type: String
      Default: "none"
    GeoRestrictionLocations:
      Type: CommaDelimitedList
      Default: ""

  Conditions:
    HasWebACL: !Not [!Equals [!Ref WebACLArn, ""]]
    HasAlias: !Not [!Equals [!Ref Aliases, ""]]
    HasOriginMtls: !Not [!Equals [!Ref OriginMtlsCertificateArn, ""]]
    HasOriginHeader: !Not [!Equals [!Ref CfOriginHeaderValue, ""]]
    HasAcmCert: !Not [!Equals [!Ref AcmCertificateArn, ""]]
    HasS3Origin: !Equals [!Ref EnableS3Origin, "true"]
    HasGeoLocations: !Not [!Equals [!Select [0, !Ref GeoRestrictionLocations], ""]]

  Resources:
    CloudFrontDistribution:
      Type: AWS::CloudFront::Distribution
      Properties:
        DistributionConfig:
          Enabled: true
          IPV6Enabled: true
          Comment: !Ref Comment
          PriceClass: !Ref PriceClass
          WebACLId: !If [HasWebACL, !Ref WebACLArn, !Ref "AWS::NoValue"]
          Aliases: !If [HasAlias, [!Ref Aliases], !Ref "AWS::NoValue"]
          DefaultRootObject: !If [HasS3Origin, "index.html", !Ref "AWS::NoValue"]

          Origins:
            - DomainName: !Ref KongDomainName
              Id: KongCloudGateway
              CustomOriginConfig:
                HTTPPort: 80
                HTTPSPort: 443
                OriginProtocolPolicy: https-only
                OriginSSLProtocols: [TLSv1.2]
                OriginReadTimeout: 30
                OriginKeepaliveTimeout: 5
              OriginMtlsConfig: !If
                - HasOriginMtls
                - ClientCertificateArn: !Ref OriginMtlsCertificateArn
                - !Ref "AWS::NoValue"
              OriginCustomHeaders: !If
                - HasOriginHeader
                - - HeaderName: !Ref CfOriginHeaderName
                    HeaderValue: !Ref CfOriginHeaderValue
                - !Ref "AWS::NoValue"
            - !If
              - HasS3Origin
              - DomainName: !Ref S3BucketDomainName
                Id: S3SPA
                S3OriginConfig:
                  OriginAccessIdentity: ""
                OriginAccessControlId: !Ref S3OACId
              - !Ref "AWS::NoValue"

          # When S3 SPA is enabled:
          #   Default behavior → S3 (serves React SPA)
          #   /api/* → Kong Cloud Gateway (API requests)
          # When S3 SPA is disabled:
          #   Default behavior → Kong Cloud Gateway (all traffic)
          DefaultCacheBehavior: !If
            - HasS3Origin
            - AllowedMethods: [GET, HEAD, OPTIONS]
              CachedMethods: [GET, HEAD]
              TargetOriginId: S3SPA
              CachePolicyId: !Ref S3CachePolicyId
              ResponseHeadersPolicyId: !Ref ResponseHeadersPolicyId
              ViewerProtocolPolicy: redirect-to-https
              Compress: true
            - AllowedMethods: [DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT]
              CachedMethods: [GET, HEAD]
              TargetOriginId: KongCloudGateway
              CachePolicyId: !Ref CachePolicyId
              OriginRequestPolicyId: !Ref OriginRequestPolicyId
              ResponseHeadersPolicyId: !Ref ResponseHeadersPolicyId
              ViewerProtocolPolicy: redirect-to-https
              Compress: true

          CacheBehaviors: !If
            - HasS3Origin
            - - PathPattern: "/api/*"
                AllowedMethods: [DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT]
                CachedMethods: [GET, HEAD]
                TargetOriginId: KongCloudGateway
                CachePolicyId: !Ref CachePolicyId
                OriginRequestPolicyId: !Ref OriginRequestPolicyId
                ResponseHeadersPolicyId: !Ref ResponseHeadersPolicyId
                ViewerProtocolPolicy: redirect-to-https
                Compress: true
            - !Ref "AWS::NoValue"

          # SPA routing: return index.html for 403/404 so React Router handles client-side routes
          CustomErrorResponses: !If
            - HasS3Origin
            - - ErrorCode: 403
                ResponseCode: 200
                ResponsePagePath: /index.html
                ErrorCachingMinTTL: 10
              - ErrorCode: 404
                ResponseCode: 200
                ResponsePagePath: /index.html
                ErrorCachingMinTTL: 10
            - !Ref "AWS::NoValue"

          ViewerCertificate: !If
            - HasAcmCert
            - AcmCertificateArn: !Ref AcmCertificateArn
              SslSupportMethod: sni-only
              MinimumProtocolVersion: TLSv1.2_2021
            - CloudFrontDefaultCertificate: true

          Restrictions:
            GeoRestriction:
              RestrictionType: !Ref GeoRestrictionType
              Locations: !If [HasGeoLocations, !Ref GeoRestrictionLocations, !Ref "AWS::NoValue"]

        Tags:
          - Key: Name
            Value: !Sub "$${Comment}-cloudfront"
          - Key: Layer
            Value: Layer2-EdgeSecurity
          - Key: Module
            Value: cloudfront

  Outputs:
    DistributionId:
      Value: !Ref CloudFrontDistribution
    DistributionArn:
      Value: !Sub "arn:aws:cloudfront::$${AWS::AccountId}:distribution/$${CloudFrontDistribution}"
    DistributionDomainName:
      Value: !GetAtt CloudFrontDistribution.DomainName
    DistributionHostedZoneId:
      Description: "CloudFront hosted zone ID (always Z2FDTNDATAQYW2)"
      Value: "Z2FDTNDATAQYW2"
  TEMPLATE
}

# ==============================================================================
# LIMITATION / WORKAROUND
# ==============================================================================
#
# Problem:
#   The Terraform AWS provider (as of v6.31) does NOT support OriginMtlsConfig
#   on the aws_cloudfront_distribution resource. AWS CloudFront origin mTLS was
#   launched in January 2026 and is supported via Console, CLI, SDK, CDK, and
#   CloudFormation — but not yet in the Terraform provider.
#
# Workaround:
#   The CloudFront distribution is created via aws_cloudformation_stack instead
#   of the native aws_cloudfront_distribution resource. This allows us to use
#   the CloudFormation AWS::CloudFront::Distribution resource which supports
#   OriginMtlsConfig with ClientCertificateArn.
#
#   All other resources (WAF Web ACL, OAC, cache policies, response headers
#   policy) remain native Terraform resources and are passed into the
#   CloudFormation stack as parameters.
#
# How to replace with native Terraform when support is added:
#   1. Watch https://github.com/hashicorp/terraform-provider-aws for a PR
#      adding origin_mtls_config to aws_cloudfront_distribution
#   2. Once available, replace the aws_cloudformation_stack.cloudfront resource
#      above with the native aws_cloudfront_distribution resource
#   3. Use `terraform state rm` to remove the CloudFormation stack from state
#   4. Use `terraform import` to import the distribution into the new resource
#   5. Update outputs.tf to reference the native resource attributes
#   6. Run `terraform apply` to verify no changes (state matches)
#   7. Delete the CloudFormation stack from the AWS console (it will be orphaned)
#
# Tracking:
#   - AWS announcement: CloudFront origin mTLS (January 2026)
#   - Terraform provider issue: TBD (open one if not yet tracked)
# ==============================================================================
