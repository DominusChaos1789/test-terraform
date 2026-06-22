###############################################################################
# Module: api_gateway_empatia
#
# Creates a REST API (API Gateway v1 - REGIONAL) with:
#   /empatia
#     /details
#       /events   POST -> Lambda proxy
#     /summary
#       /events   POST -> Lambda proxy
#
# Auth   : Cognito User Pools authorizer (OAuth2 Bearer token)
# Stage  : dev-1
# WAF    : associated via aws_wafv2_web_acl_association (separate resource)
###############################################################################

variable "api_name" {
  default = "empatia-transcripts-api"
}

variable "stage_name" {
  default = "dev-1"
}

variable "lambda_invoke_arn" {
  description = "Invoke ARN of the Lambda function handling /details and /summary"
  type        = string
}

variable "lambda_function_name" {
  description = "Name of the Lambda function (for permission statement)"
  type        = string
}

variable "cognito_user_pool_arn" {
  description = "ARN of the Cognito User Pool — from module.cognito.user_pool_arn"
  type        = string
}

variable "client_name" {
  description = "Used to name the usage plan for this client"
  default     = "empatia-client"
}

###############################################################################
# REST API
###############################################################################

resource "aws_api_gateway_rest_api" "this" {
  name = var.api_name

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

###############################################################################
# Cognito Authorizer
###############################################################################

resource "aws_api_gateway_authorizer" "cognito" {
  name            = "empatia-cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.this.id
  type            = "COGNITO_USER_POOLS"
  identity_source = "method.request.header.Authorization"

  provider_arns = [var.cognito_user_pool_arn]
}

###############################################################################
# Resources: /empatia /details /events  and  /empatia /summary /events
###############################################################################

resource "aws_api_gateway_resource" "empatia" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "empatia"
}

resource "aws_api_gateway_resource" "details" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.empatia.id
  path_part   = "details"
}

resource "aws_api_gateway_resource" "details_events" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.details.id
  path_part   = "events"
}

resource "aws_api_gateway_resource" "summary" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.empatia.id
  path_part   = "summary"
}

resource "aws_api_gateway_resource" "summary_events" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.summary.id
  path_part   = "events"
}

###############################################################################
# /empatia/details/events  — POST
###############################################################################

resource "aws_api_gateway_method" "details_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.details_events.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

  # Require the transcripts:write scope on the token
  authorization_scopes = [
    "${var.cognito_resource_server_identifier}/transcripts:write"
  ]
}

resource "aws_api_gateway_integration" "details_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.details_events.id
  http_method             = aws_api_gateway_method.details_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
}

###############################################################################
# /empatia/summary/events  — POST
###############################################################################

resource "aws_api_gateway_method" "summary_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.summary_events.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

  authorization_scopes = [
    "${var.cognito_resource_server_identifier}/transcripts:write"
  ]
}

resource "aws_api_gateway_integration" "summary_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.summary_events.id
  http_method             = aws_api_gateway_method.summary_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
}

###############################################################################
# Lambda permission — allow API Gateway to invoke
###############################################################################

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

###############################################################################
# Deployment + Stage
###############################################################################

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.details_events.id,
      aws_api_gateway_resource.summary_events.id,
      aws_api_gateway_method.details_post.id,
      aws_api_gateway_method.summary_post.id,
      aws_api_gateway_integration.details_post.id,
      aws_api_gateway_integration.summary_post.id,
      aws_api_gateway_authorizer.cognito.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name
}

###############################################################################
# Usage Plan (throttling / quota per client)
###############################################################################

resource "aws_api_gateway_usage_plan" "this" {
  name = "${var.client_name}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = 10
    burst_limit = 20
  }

  quota_settings {
    limit  = 10000
    period = "DAY"
  }
}

###############################################################################
# Extra variable needed for scope — add to variable block
###############################################################################

variable "cognito_resource_server_identifier" {
  description = "Resource server identifier — from module.cognito scope output"
  type        = string
  # e.g. https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1
}

###############################################################################
# Outputs
###############################################################################

output "invoke_url" {
  value = aws_api_gateway_stage.this.invoke_url
}

output "details_endpoint" {
  value = "${aws_api_gateway_stage.this.invoke_url}/empatia/details/events"
}

output "summary_endpoint" {
  value = "${aws_api_gateway_stage.this.invoke_url}/empatia/summary/events"
}