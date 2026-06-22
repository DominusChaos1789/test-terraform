###############################################################################
# Module: cognito_empatia
#
# Creates the Cognito infrastructure for OAuth2 Client Credentials flow:
#
#   - User Pool              : the identity authority
#   - Resource Server        : represents the API (defines the scope)
#   - App Client             : the machine credentials the client uses
#                              (client_id + client_secret, no human login)
#   - User Pool Domain       : exposes the /oauth2/token endpoint
#
# Flow:
#   Client -> POST /oauth2/token (client_credentials grant)
#          -> receives access_token (JWT)
#          -> API Gateway validates token via Cognito authorizer
#          -> Lambda handler runs
###############################################################################

variable "stack_id" {
  description = "Stack identifier prefix, e.g. augusta-nexa-dev"
  default     = "augusta-nexa-dev"
}

variable "client_name" {
  description = "Name of the API consumer client (used to name the app client)"
  default     = "empatia-client"
}

variable "cognito_domain_prefix" {
  description = "Unique subdomain prefix for the Cognito hosted UI / token endpoint"
  default     = "empatia-auth"
  # Token URL will be:
  # https://empatia-auth.auth.us-east-2.amazoncognito.com/oauth2/token
}

variable "token_validity_hours" {
  description = "Access token validity in hours"
  default     = 1
}

###############################################################################
# User Pool
###############################################################################

resource "aws_cognito_user_pool" "this" {
  name = "${var.stack_id}-empatia-pool"

  # This is a machine-to-machine (M2M) pool — no human sign-up or password
  # policies needed. Disable all self-service features.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # No email/SMS needed for M2M
  auto_verified_attributes = []

  # Password policy required by Terraform even for M2M pools
  password_policy {
    minimum_length                   = 16
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 1
  }

  tags = {
    Stack   = var.stack_id
    Service = "empatia"
  }
}

###############################################################################
# User Pool Domain
# Exposes: https://<prefix>.auth.<region>.amazoncognito.com/oauth2/token
###############################################################################

resource "aws_cognito_user_pool_domain" "this" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}

###############################################################################
# Resource Server
# Represents your API and defines the OAuth2 scope the client will request.
# Scope format: <identifier>/<scope_name>
###############################################################################

resource "aws_cognito_resource_server" "this" {
  name         = "empatia-transcripts-api"
  identifier   = "https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1"
  user_pool_id = aws_cognito_user_pool.this.id

  scope {
    scope_name        = "transcripts:write"
    scope_description = "Allows posting conversation transcripts and summaries"
  }
}

###############################################################################
# App Client  (machine-to-machine — client credentials only)
###############################################################################

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.client_name}-app-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # Generate a client secret — required for client_credentials grant
  generate_secret = true

  # Only allow the client_credentials OAuth2 grant type (no human login flows)
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true

  # Attach the scope defined in the resource server above
  # Format: <resource_server_identifier>/<scope_name>
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.this.identifier}/transcripts:write"
  ]

  # No callback/logout URLs needed for M2M
  supported_identity_providers = ["COGNITO"]

  # Token validity
  access_token_validity  = var.token_validity_hours
  refresh_token_validity = 1   # days — not used in M2M but required by schema

  token_validity_units {
    access_token  = "hours"
    refresh_token = "days"
  }

  # Prevent user password auth — M2M only
  explicit_auth_flows = []

  depends_on = [aws_cognito_resource_server.this]
}

###############################################################################
# Outputs — wire these into apigateway_module.tf and lambda.tf
###############################################################################

output "user_pool_id" {
  description = "Cognito User Pool ID — used in the API Gateway authorizer providerARNs"
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN — used in api-docs.json and the authorizer"
  value       = aws_cognito_user_pool.this.arn
}

output "client_id" {
  description = "App client ID — the client sends this when requesting a token"
  value       = aws_cognito_user_pool_client.this.id
}

output "client_secret" {
  description = "App client secret — keep this safe, share only with the API consumer"
  value       = aws_cognito_user_pool_client.this.client_secret
  sensitive   = true
}

output "token_url" {
  description = "OAuth2 token endpoint — client posts here for an access token"
  value       = "https://${var.cognito_domain_prefix}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/token"
}

output "scope" {
  description = "OAuth2 scope the client must request"
  value       = "${aws_cognito_resource_server.this.identifier}/transcripts:write"
}

###############################################################################
# Data sources
###############################################################################

data "aws_region" "current" {}