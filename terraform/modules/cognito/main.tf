# MunchGo Authentication - Amazon Cognito User Pool
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# LAYER 1: Cloud Foundations
# Cognito User Pool for MunchGo end-user authentication (registration, login, JWT).
# Replaces the custom JWT implementation in munchgo-auth-service.
#
# Components:
#   - User Pool with email verification and password policies
#   - App Client (public, no secret — for SPA/mobile)
#   - User Pool Groups mapped to MunchGo roles
#   - Pre Token Generation Lambda v2 (injects custom claims: roles, userId)
#   - Secrets Manager entry for config distribution via External Secrets
#
# Integration:
#   - Kong Cloud Gateway validates Cognito JWTs via openid-connect plugin
#   - Auth service calls Cognito Admin APIs via AWS SDK (IRSA)
#   - External Secrets syncs Cognito config to K8s secrets

# ==============================================================================
# COGNITO USER POOL
# ==============================================================================

resource "aws_cognito_user_pool" "munchgo" {
  name = "${var.name_prefix}-munchgo-users"

  # Username configuration — email as primary sign-in
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Username case insensitivity
  username_configuration {
    case_sensitive = false
  }

  # Password policy
  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  # Account recovery via email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Schema attributes
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  schema {
    name                = "given_name"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  schema {
    name                = "family_name"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  # Email configuration (Cognito default sender)
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # MFA configuration (optional, off by default for POC)
  mfa_configuration = var.enable_mfa ? "ON" : "OFF"

  # Pre Token Generation Lambda trigger
  # Adds custom claims (roles, userId) to Cognito tokens
  lambda_config {
    pre_token_generation_config {
      lambda_arn     = aws_lambda_function.pre_token_generation.arn
      lambda_version = "V2_0"
    }
  }

  # Deletion protection (off for POC, enable for prod)
  deletion_protection = var.deletion_protection ? "ACTIVE" : "INACTIVE"

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-cognito"
    Layer  = "Layer1-CloudFoundations"
    Module = "cognito"
  })
}

# ==============================================================================
# COGNITO USER POOL DOMAIN
# ==============================================================================

resource "aws_cognito_user_pool_domain" "munchgo" {
  domain       = "${var.name_prefix}-munchgo"
  user_pool_id = aws_cognito_user_pool.munchgo.id
}

# ==============================================================================
# COGNITO APP CLIENT (Public — no client secret)
# ==============================================================================
# Public client for SPA/mobile. The auth-service also uses this client via
# Admin APIs (IRSA-authenticated, doesn't need client secret).

resource "aws_cognito_user_pool_client" "munchgo_app" {
  name         = "${var.name_prefix}-munchgo-app"
  user_pool_id = aws_cognito_user_pool.munchgo.id

  # Auth flows
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  # No client secret (public client for SPA/mobile)
  generate_secret = false

  # Token validity
  access_token_validity  = 1  # 1 hour
  id_token_validity      = 1  # 1 hour
  refresh_token_validity = 7  # 7 days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Prevent user existence errors (security best practice)
  prevent_user_existence_errors = "ENABLED"

  # Supported identity providers
  supported_identity_providers = ["COGNITO"]

  # OAuth scopes (for OIDC discovery)
  # Only enable code flow when callback URLs are provided (e.g., SPA with hosted UI).
  # For API-only auth (admin-initiate-auth), no OAuth flows are needed.
  allowed_oauth_flows                  = length(var.callback_urls) > 0 ? ["code"] : null
  allowed_oauth_flows_user_pool_client = length(var.callback_urls) > 0
  allowed_oauth_scopes                 = length(var.callback_urls) > 0 ? ["openid", "email", "profile"] : null
  callback_urls                        = length(var.callback_urls) > 0 ? var.callback_urls : null
  logout_urls                          = length(var.logout_urls) > 0 ? var.logout_urls : null

  # Read attributes (what the app can read)
  read_attributes = [
    "email",
    "email_verified",
    "given_name",
    "family_name",
  ]

  # Write attributes (what the app can write)
  write_attributes = [
    "email",
    "given_name",
    "family_name",
  ]
}

# ==============================================================================
# COGNITO USER POOL GROUPS (Map to MunchGo roles)
# ==============================================================================

resource "aws_cognito_user_group" "roles" {
  for_each = toset(var.user_pool_groups)

  name         = each.value
  user_pool_id = aws_cognito_user_pool.munchgo.id
  description  = "MunchGo role: ${each.value}"
}

# ==============================================================================
# PRE TOKEN GENERATION LAMBDA v2
# ==============================================================================
# Enriches Cognito tokens with custom claims:
#   - custom:roles — user's Cognito group memberships (maps to MunchGo roles)
# This allows Kong's openid-connect plugin to read roles from the token
# and forward them as upstream headers.

data "archive_file" "pre_token_generation" {
  type        = "zip"
  source_file = "${path.module}/lambda/pre_token_generation.py"
  output_path = "${path.module}/lambda/pre_token_generation.zip"
}

resource "aws_lambda_function" "pre_token_generation" {
  function_name = "${var.name_prefix}-munchgo-pre-token"
  description   = "MunchGo Cognito Pre Token Generation v2 — adds roles claim"

  filename         = data.archive_file.pre_token_generation.output_path
  source_code_hash = data.archive_file.pre_token_generation.output_base64sha256
  handler          = "pre_token_generation.lambda_handler"
  runtime          = "python3.12"
  timeout          = 5
  memory_size      = 128

  role = aws_iam_role.lambda_execution.arn

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-pre-token-lambda"
    Layer  = "Layer1-CloudFoundations"
    Module = "cognito"
  })
}

# Allow Cognito to invoke the Lambda
resource "aws_lambda_permission" "cognito_invoke" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_token_generation.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.munchgo.arn
}

# Lambda execution role
resource "aws_iam_role" "lambda_execution" {
  name = "role-cognito-lambda-${var.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = merge(var.tags, {
    Name   = "role-cognito-lambda-${var.name_prefix}"
    Layer  = "Layer1-CloudFoundations"
    Module = "cognito"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ==============================================================================
# SECRETS MANAGER - Cognito Configuration
# ==============================================================================
# Stores Cognito User Pool config in Secrets Manager for:
#   - External Secrets Operator → K8s Secret → auth-service env vars
#   - Kong openid-connect plugin configuration (issuer URL)

resource "aws_secretsmanager_secret" "cognito_config" {
  name_prefix = "${var.name_prefix}-munchgo-cognito-"
  description = "MunchGo Cognito User Pool configuration for auth-service and Kong OIDC"

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-cognito-secret"
    Layer  = "Layer1-CloudFoundations"
    Module = "cognito"
  })
}

resource "aws_secretsmanager_secret_version" "cognito_config" {
  secret_id = aws_secretsmanager_secret.cognito_config.id
  secret_string = jsonencode({
    user_pool_id  = aws_cognito_user_pool.munchgo.id
    app_client_id = aws_cognito_user_pool_client.munchgo_app.id
    region        = var.region
    issuer_url    = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.munchgo.id}"
    jwks_uri      = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.munchgo.id}/.well-known/jwks.json"
    domain        = "https://${aws_cognito_user_pool_domain.munchgo.domain}.auth.${var.region}.amazoncognito.com"
  })
}
