###############################################################################
# Integration glue: links Lambda <-> API Gateway (trigger) and Lambda -> SQS
#
# Two different relationships happen here, and they ARE NOT the same thing:
#
# 1) API Gateway "triggers" the Lambda
#    -> This is just permission + integration wiring (already in your
#       apigateway_module.tf): aws_api_gateway_integration (type=AWS_PROXY)
#       + aws_lambda_permission(principal=apigateway.amazonaws.com).
#       There is no separate "trigger" resource for synchronous APIGW->Lambda.
#
# 2) Lambda sends to SQS as a "destination"
#    -> SQS is NOT a Lambda "destination" in the AWS sense (destinations only
#       apply to ASYNC invocations success/failure routing, e.g. Lambda ->
#       SNS/SQS/Lambda/EventBridge on error). Since API Gateway invokes your
#       Lambda SYNCHRONOUSLY (proxy integration waits for the response),
#       there is no native "on success destination" you can attach.
#
#    Instead, your Lambda code itself calls sqs.send_message() (which is
#    exactly what lambda_handler.py already does). Terraform's job here is
#    only to grant the IAM permission - already done in lambda.tf via
#    aws_iam_role_policy "lambda_permissions".
#
# If you specifically want a "fire-and-forget, no Lambda code involved"
# setup, the real native pattern is: API Gateway -> SQS directly (skipping
# Lambda on the write path), and Lambda only consumes from SQS afterward.
# That alternative is included at the bottom of this file, commented out.
###############################################################################


###############################################################################
# OPTION A (your current architecture) — confirm the linkage is complete
###############################################################################

# This already exists in apigateway_module.tf, restated here for clarity:
#
# resource "aws_api_gateway_integration" "details_post" {
#   ...
#   type = "AWS_PROXY"
#   uri  = var.lambda_invoke_arn          # <-- this IS the "trigger" link
# }
#
# resource "aws_lambda_permission" "apigw" {
#   action        = "lambda:InvokeFunction"
#   function_name = var.lambda_function_name
#   principal     = "apigateway.amazonaws.com"
#   source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
# }
#
# And this already exists in lambda.tf:
#
# resource "aws_iam_role_policy" "lambda_permissions" {
#   ...
#   Action   = ["sqs:SendMessage"]
#   Resource = var.sqs_queue_arn
# }
#
# => Nothing more is needed for "API Gateway triggers Lambda, Lambda sends to SQS".
#    Just make sure both modules are wired together in root main.tf:

# --------------------------- root main.tf example ---------------------------
#
# module "sqs" {
#   source = "./modules/sqs"
# }
#
# module "lambda" {
#   source         = "./modules/lambda_empatia_ingest"
#   sqs_queue_arn  = module.sqs.queue_arn
#   sqs_queue_url  = module.sqs.queue_url
#   s3_bucket_name = "landing"
#   s3_bucket_arn  = module.s3.bucket_arn
# }
#
# module "api_gateway" {
#   source               = "./modules/api_gateway_empatia"
#   lambda_invoke_arn    = module.lambda.lambda_invoke_arn
#   lambda_function_name = module.lambda.lambda_function_name
# }
#
# ------------------------------------------------------------------------------


###############################################################################
# OPTION B — Native API Gateway -> SQS direct integration (no Lambda on write)
#
# Uncomment + adapt if you'd rather have API Gateway write straight to SQS
# (lower latency, no Lambda cold start) and have a SEPARATE Lambda consume
# from SQS afterward (event source mapping) to do the S3 write + validation.
###############################################################################

# resource "aws_iam_role" "apigw_sqs_role" {
#   name = "apigw-to-sqs-role"
#
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Action    = "sts:AssumeRole"
#       Effect    = "Allow"
#       Principal = { Service = "apigateway.amazonaws.com" }
#     }]
#   })
# }
#
# resource "aws_iam_role_policy" "apigw_sqs_send" {
#   name = "apigw-sqs-send"
#   role = aws_iam_role.apigw_sqs_role.id
#
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Effect   = "Allow"
#       Action   = ["sqs:SendMessage"]
#       Resource = var.sqs_queue_arn
#     }]
#   })
# }
#
# resource "aws_api_gateway_integration" "details_post_sqs" {
#   rest_api_id             = aws_api_gateway_rest_api.this.id
#   resource_id             = aws_api_gateway_resource.details_events.id
#   http_method             = aws_api_gateway_method.details_post.http_method
#   type                    = "AWS"
#   integration_http_method = "POST"
#   uri                     = "arn:aws:apigateway:${var.aws_region}:sqs:path/${var.aws_account_id}/${var.sqs_queue_name}"
#   credentials             = aws_iam_role.apigw_sqs_role.arn
#
#   request_parameters = {
#     "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
#   }
#
#   # API Gateway must transform the JSON body into the
#   # x-www-form-urlencoded format SQS's SendMessage action expects
#   request_templates = {
#     "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
#   }
# }
#
# resource "aws_api_gateway_method_response" "details_post_200" {
#   rest_api_id = aws_api_gateway_rest_api.this.id
#   resource_id = aws_api_gateway_resource.details_events.id
#   http_method = aws_api_gateway_method.details_post.http_method
#   status_code = "200"
# }
#
# resource "aws_api_gateway_integration_response" "details_post_200" {
#   rest_api_id = aws_api_gateway_rest_api.this.id
#   resource_id = aws_api_gateway_resource.details_events.id
#   http_method = aws_api_gateway_method.details_post.http_method
#   status_code = aws_api_gateway_method_response.details_post_200.status_code
# }
#
# # Separate Lambda consumes the queue via Event Source Mapping
# resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
#   event_source_arn = var.sqs_queue_arn
#   function_name    = aws_lambda_function.consumer.arn
#   batch_size       = 10
# }
