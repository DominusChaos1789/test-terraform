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
# Auth   : API Key + Usage Plan (per-client throttling/quota)
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

variable "client_name" {
  description = "Used to name the API key / usage plan for this client"
  default     = "cariai-client"
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
# /empatia
###############################################################################

resource "aws_api_gateway_resource" "empatia" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "empatia"
}

###############################################################################
# /empatia/details
###############################################################################

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

###############################################################################
# /empatia/summary
###############################################################################

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
# Reusable: POST method + Lambda proxy integration
# (repeated for /details/events and /summary/events)
###############################################################################

# ---- /empatia/details/events -----------------------------------------------

resource "aws_api_gateway_method" "details_post" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.details_events.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "details_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.details_events.id
  http_method             = aws_api_gateway_method.details_post.http_method
  integration_http_method = "POST"
  type                     = "AWS_PROXY"
  uri                      = var.lambda_invoke_arn
}

# ---- /empatia/summary/events ------------------------------------------------

resource "aws_api_gateway_method" "summary_post" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.summary_events.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "summary_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.summary_events.id
  http_method             = aws_api_gateway_method.summary_post.http_method
  integration_http_method = "POST"
  type                     = "AWS_PROXY"
  uri                      = var.lambda_invoke_arn
}

###############################################################################
# Lambda permission - allow API Gateway to invoke
###############################################################################

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"

  # */* allows any method/resource on this API to invoke the function
  source_arn = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

###############################################################################
# Deployment + Stage
###############################################################################

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Forces a new deployment whenever any of these resources change
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.details_events.id,
      aws_api_gateway_resource.summary_events.id,
      aws_api_gateway_method.details_post.id,
      aws_api_gateway_method.summary_post.id,
      aws_api_gateway_integration.details_post.id,
      aws_api_gateway_integration.summary_post.id,
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
# API Key + Usage Plan (per-client auth & throttling)
###############################################################################

resource "aws_api_gateway_api_key" "client" {
  name = "${var.client_name}-key"
}

resource "aws_api_gateway_usage_plan" "this" {
  name = "${var.client_name}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = 10   # requests per second
    burst_limit = 20
  }

  quota_settings {
    limit  = 10000     # requests
    period = "DAY"
  }
}

resource "aws_api_gateway_usage_plan_key" "client" {
  key_id        = aws_api_gateway_api_key.client.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}

###############################################################################
# Outputs
###############################################################################

output "invoke_url" {
  value = "${aws_api_gateway_stage.this.invoke_url}"
  # e.g. https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1
}

output "details_endpoint" {
  value = "${aws_api_gateway_stage.this.invoke_url}/empatia/details/events"
}

output "summary_endpoint" {
  value = "${aws_api_gateway_stage.this.invoke_url}/empatia/summary/events"
}

output "api_key_value" {
  value     = aws_api_gateway_api_key.client.value
  sensitive = true
}
