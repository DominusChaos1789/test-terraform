###############################################################################
# Root main.tf — wires Cognito + Lambda + API Gateway together
###############################################################################

###############################################################################
# Cognito — User Pool, App Client, Resource Server, Domain
###############################################################################

module "cognito" {
  source = "./modules/cognito_empatia"

  stack_id              = "augusta-nexa-dev"
  client_name           = "empatia-client"
  cognito_domain_prefix = "empatia-auth"
  token_validity_hours  = 1
}

###############################################################################
# Lambda — handler + IAM role + log group
###############################################################################

module "lambda" {
  source = "./modules/lambda_empatia_ingest"

  function_name  = "empatia-transcripts-ingest"
  sqs_queue_arn  = module.sqs.queue_arn
  sqs_queue_url  = module.sqs.queue_url
  s3_bucket_name = "augusta-nexa-dev"
  s3_bucket_arn  = module.s3.bucket_arn
  allowed_origin = "https://empatia.tuempresa.com"  # replace with real domain
}

###############################################################################
# API Gateway — REST API, Cognito authorizer, methods, integrations, stage
###############################################################################

module "api_gateway" {
  source = "./modules/api_gateway_empatia"

  lambda_invoke_arn                  = module.lambda.lambda_invoke_arn
  lambda_function_name               = module.lambda.lambda_function_name
  cognito_user_pool_arn              = module.cognito.user_pool_arn
  cognito_resource_server_identifier = module.cognito.scope
}

###############################################################################
# Useful outputs after apply
###############################################################################

output "token_url" {
  description = "POST here with client_id + client_secret to get a Bearer token"
  value       = module.cognito.token_url
}

output "client_id" {
  description = "Send to the API consumer"
  value       = module.cognito.client_id
}

output "client_secret" {
  description = "Send to the API consumer — keep this safe"
  value       = module.cognito.client_secret
  sensitive   = true
}

output "details_endpoint" {
  value = module.api_gateway.details_endpoint
}

output "summary_endpoint" {
  value = module.api_gateway.summary_endpoint
}