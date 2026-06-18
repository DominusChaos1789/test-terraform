###############################################################################
# modules/api_gateway/main.tf
# Crea un API REST con un path base (empatia) y N subrecursos, cada uno
# con su propio /events, todos apuntando al MISMO Lambda via proxy.
#
# Resultado con base_path="empatia" y endpoints=["detalle","resumen"]:
#   /empatia/detalle/events   (POST)
#   /empatia/resumen/events   (POST)
#
# El Lambda diferencia cual es cual mirando event["resource"].
#
# NOTA: La asociacion con el WAF (aws_wafv2_web_acl_association) y el
# API Key / Usage Plan para el token del cliente se agregan en este mismo
# modulo mas abajo.
###############################################################################

variable "api_name" {
  type = string
}

variable "stage_name" {
  type = string
}

variable "lambda_invoke_arn" {
  type = string
}

variable "lambda_function_name" {
  type = string
}

variable "base_path" {
  description = "Path base, ej 'empatia'"
  type        = string
}

variable "endpoints" {
  description = "Lista de sub-recursos, ej ['detalle','resumen']"
  type        = list(string)
}

resource "aws_api_gateway_rest_api" "this" {
  name = var.api_name
}

# /empatia
resource "aws_api_gateway_resource" "base" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = var.base_path
}

# /empatia/{detalle|resumen}
resource "aws_api_gateway_resource" "tipo" {
  for_each    = toset(var.endpoints)
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.base.id
  path_part   = each.value
}

# /empatia/{detalle|resumen}/events
resource "aws_api_gateway_resource" "events" {
  for_each    = toset(var.endpoints)
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.tipo[each.key].id
  path_part   = "events"
}

resource "aws_api_gateway_method" "post" {
  for_each      = toset(var.endpoints)
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.events[each.key].id
  http_method   = "POST"
  authorization = "NONE"      # la autenticacion la da el API Key, no IAM/Cognito
  api_key_required = true     # <- esto exige el token (x-api-key) del cliente
}

resource "aws_api_gateway_integration" "lambda" {
  for_each                = toset(var.endpoints)
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.events[each.key].id
  http_method             = aws_api_gateway_method.post[each.key].http_method
  integration_http_method = "POST"
  type                     = "AWS_PROXY" # Lambda proxy integration
  uri                      = var.lambda_invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.events,
      aws_api_gateway_method.post,
      aws_api_gateway_integration.lambda,
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
# API KEY + USAGE PLAN
# Esto es lo que le da al cliente el "token" para usar la API
# (se manda como header: x-api-key)
###############################################################################
resource "aws_api_gateway_api_key" "client" {
  name = "${var.api_name}-client-key"
}

resource "aws_api_gateway_usage_plan" "this" {
  name = "${var.api_name}-usage-plan"

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

resource "aws_api_gateway_usage_plan_key" "this" {
  key_id        = aws_api_gateway_api_key.client.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}

###############################################################################
# WAF association
# Si ya tenes el Web ACL creado en otro lado, pasa su ARN como variable
# y descomenta este recurso (o agregalo en main.tf donde tengas el WAF).
###############################################################################
# resource "aws_wafv2_web_acl_association" "this" {
#   resource_arn = aws_api_gateway_stage.this.arn
#   web_acl_arn  = var.waf_web_acl_arn
# }

output "invoke_url" {
  value = aws_api_gateway_stage.this.invoke_url
}

output "api_key_value" {
  value     = aws_api_gateway_api_key.client.value
  sensitive = true
}
