# Migrating from API Gateway → SQS (direct) to API Gateway → Lambda → SQS

## 1. Confirm what's actually deployed vs what's in your .tf files

Run this to see the real current state of the integration resources:

```bash
terraform state list | grep aws_api_gateway_integration
```

Then inspect each one:

```bash
terraform state show 'aws_api_gateway_integration.details_post'
terraform state show 'aws_api_gateway_integration.summary_post'
```

Look at the `type` and `uri` attributes:
- `type = "AWS"` and `uri` contains `:sqs:path/` → this is the direct-to-SQS integration (what's currently live)
- `type = "AWS_PROXY"` and `uri` contains `:lambda:` → this is what you want

If the state shows `"AWS"` but your `.tf` file shows `"AWS_PROXY"`, your applied infrastructure and your code are out of sync — likely from a manual console change, or you're not actually running `terraform apply` against the file you think you are (check you're in the right directory / workspace).

## 2. Make sure the Lambda module is deployed and wired in

Confirm the Lambda exists and SQS permissions are attached:

```bash
terraform state show 'module.lambda.aws_lambda_function.this'
terraform state show 'module.lambda.aws_iam_role_policy.lambda_permissions'
```

If the Lambda module was never applied, apply it first:

```bash
terraform apply -target=module.lambda
```

## 3. Remove the old SQS-direct integration resources

If your actual `.tf` files (not just state) still define the AWS/SQS integration resources
(`aws_api_gateway_integration` with type AWS, `aws_api_gateway_method_response`,
`aws_api_gateway_integration_response`, `aws_iam_role.apigw_sqs_role`, etc.), delete those
resource blocks from your `.tf` files entirely. Don't just comment them out — Terraform
needs to see them gone to plan a destroy.

## 4. Make sure your method + integration use the Lambda proxy pattern

This should be the only integration block per resource/method:

```hcl
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
```

(This is already exactly what's in `apigateway_module.tf` — just make sure it's the version
actually being applied.)

## 5. Plan first — don't apply blindly

```bash
terraform plan
```

You should see something like:

```
  # aws_api_gateway_integration.details_post will be updated in-place
  ~ type = "AWS" -> "AWS_PROXY"
  ~ uri  = "arn:aws:apigateway:...:sqs:path/..." -> "arn:aws:apigateway:...:lambda:path/..."

  # aws_lambda_permission.apigw will be created
```

If you see resources being destroyed that you didn't expect (like the whole REST API), STOP
and review — that usually means a `path_part` or resource ID changed and Terraform thinks
it's a totally different resource tree.

## 6. Apply

```bash
terraform apply
```

## 7. Force a new deployment

API Gateway deployments are immutable snapshots — changing the integration type alone
doesn't push it live until you redeploy. The `triggers` block in `apigateway_module.tf`
should already force this automatically since it hashes the integration IDs. Confirm with:

```bash
terraform state show 'aws_api_gateway_deployment.this'
```

Check the `triggers.redeployment` value changed after apply.

## 8. Verify in Postman

Re-run the "POST Details - Valid" request. You should now get:

```json
{
  "message": "Transcript received successfully.",
  "record_id": "...",
  "endpoint": "details",
  "s3_key": "transcripts/details/2026/06/16/....json"
}
```

with status `202`, not the SQS `SendMessageResponse` body with status `200`.

## 9. Clean up orphaned IAM role (if it existed)

If step 1 revealed an `aws_iam_role.apigw_sqs_role` (the role allowing API Gateway to call
SQS directly), remove it from your `.tf` files too once you confirm nothing else uses it —
otherwise it'll sit unused in AWS, which isn't harmful but is clutter.
