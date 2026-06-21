# Empatia Transcripts API

Ingestion API for conversation transcripts (**details**) and conversation
summaries (**summary**) from client systems. Each request is validated,
queued in SQS, and landed as JSON in S3 under Hive-style date partitions.

```
Client → Amazon Cognito (OAuth2 Bearer token)
       → API Gateway (REST, regional, dev-1 stage)
       → Lambda (validates payload)
       → SQS (queues for downstream processing)
       → S3 landing bucket (augusta-nexa-dev)
```

## Base URL

```
https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1
```

## Endpoints

| Method | Path                       | Purpose                          |
|--------|----------------------------|-----------------------------------|
| POST   | `/empatia/details/events`  | Full conversation transcript      |
| POST   | `/empatia/summary/events`  | Conversation summary (motivo/resumen) |

Both require an `Authorization: Bearer <token>` header (Cognito User Pools
authorizer at the API Gateway level).

## S3 landing paths

```
augusta-nexa-dev/empatia/transcripciones/detalle/api/year=YYYY/month=MM/day=DD/<record_id>.json
augusta-nexa-dev/empatia/transcripciones/resumen/api/year=YYYY/month=MM/day=DD/<record_id>.json
```

Partitions use Hive `key=value` format so Glue Crawler / Athena pick up
`year`, `month`, `day` as partition columns automatically.

## Request schema

Both endpoints share a common set of fields; only the `data` object differs.

**Common fields**

| Field                      | Required | Notes                                       |
|-----------------------------|----------|----------------------------------------------|
| `tenant_id`                  | yes      |                                                |
| `idLlamada`                   | no       | Unique call ID                                |
| `tipoPersona`                  | yes      | `"Natural"` or `"Juridica"`                  |
| `tipoIdentificacion`            | yes      |                                                |
| `numeroIdentificacion`           | yes      |                                                |
| `primerNombre`, `primerApellido` | conditional | required if `tipoPersona = "Natural"`     |
| `razonSocial`                    | conditional | required if `tipoPersona = "Juridica"`    |
| `codigoTipificacion`              | yes      |                                                |
| `descripcionTipificacion`          | no       |                                                |
| `fechaInicio`                       | no       |                                                |
| `data`                                | yes      | shape depends on endpoint (see below)         |

**`/details/events` → `data`**
```json
{ "data": { "conversacion": "full transcript text..." } }
```

**`/summary/events` → `data`**
```json
{ "data": { "motivo": "...", "resumen": "..." } }
```

## Responses

| Code | Meaning                                                    |
|------|--------------------------------------------------------------|
| 202  | Accepted — queued in SQS and written to S3                   |
| 400  | Invalid JSON or missing/invalid fields (see error message)   |
| 401  | Missing or invalid Bearer token                               |
| 403  | Token valid but lacks required scope/access                  |
| 404  | Unknown endpoint                                              |
| 405  | Wrong HTTP method                                              |
| 500  | Internal error (SQS send failed) — safe to retry              |

Success example:
```json
{
  "message": "Transcript received successfully.",
  "record_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "endpoint": "details",
  "s3_key": "empatia/transcripciones/detalle/api/year=2026/month=06/day=21/f47ac10b-....json"
}
```

## Repo contents

| File | Purpose |
|------|---------|
| `lambda_handler.py` | Lambda function: validates payload, sends to SQS, writes to S3 |
| `lambda.tf` | Terraform module — Lambda function, IAM role/policy, log group |
| `apigateway_module.tf` | Terraform module — REST API, resources, methods, `AWS_PROXY` integrations, API key/usage plan |
| `integration_glue.tf` | Notes + reference code on how API Gateway triggers Lambda and how Lambda sends to SQS (includes a commented-out direct API Gateway→SQS alternative) |
| `api-docs.json` | Swagger 2.0 spec with `x-amazon-apigateway-integration` and Cognito authorizer extensions — importable via `aws apigateway import-rest-api` |
| `empatia_api.postman_collection.json` | Postman collection: OAuth2 token request + valid/invalid cases for both endpoints |
| `postman_testing_guide.md` | Manual step-by-step guide for testing in Postman |
| `migration_steps.md` | Steps to migrate from a direct API Gateway→SQS integration to API Gateway→Lambda→SQS |
| `local_test/run_local.py` | Runs `lambda_handler.py` locally with mocked `boto3` (no AWS calls) |
| `local_test/event_*.json` | Sample API Gateway proxy events for local testing (valid + invalid cases) |

## Testing locally (no AWS calls)

```bash
cd local_test
pip install boto3 --break-system-packages
cp ../lambda_handler.py .
python3 run_local.py event_details.json
python3 run_local.py event_summary.json
python3 run_local.py event_bad_missing_fields.json
python3 run_local.py event_bad_persona_mismatch.json
python3 run_local.py event_bad_juridica_missing_razon.json
```

Prints the Lambda's HTTP response plus the mocked SQS `send_message` and S3
`put_object` calls it would have made.

## Testing with Postman

1. Import `empatia_api.postman_collection.json`.
2. Set collection variables: `base_url`, `token_url`, `client_id`, `client_secret`.
3. Run **Auth → Get OAuth2 Token** first — it saves the token into `{{access_token}}` automatically.
4. Run any request in **Details** or **Summary** — Bearer auth is inherited from the collection.

See `postman_testing_guide.md` for manual (non-collection) steps and a full
test checklist, including S3/SQS verification.

## Deploying with Terraform

```hcl
module "lambda" {
  source         = "./modules/lambda_empatia_ingest"
  sqs_queue_arn  = module.sqs.queue_arn
  sqs_queue_url  = module.sqs.queue_url
  s3_bucket_name = "augusta-nexa-dev"
  s3_bucket_arn  = module.s3.bucket_arn
}

module "api_gateway" {
  source                = "./modules/api_gateway_empatia"
  lambda_invoke_arn     = module.lambda.lambda_invoke_arn
  lambda_function_name  = module.lambda.lambda_function_name
}
```

```bash
terraform plan
terraform apply
```

Required Lambda environment variables: `SQS_QUEUE_URL`, `S3_BUCKET`.

Required IAM permissions on the Lambda role: `sqs:SendMessage` (scoped to
the queue ARN), `s3:PutObject` (scoped to the bucket's transcript prefixes),
plus the standard CloudWatch Logs trio.

## Known config placeholders to fill in

- `api-docs.json`: `ACCOUNT_ID` (Lambda + Cognito ARNs), `USER_POOL_ID`
- `empatia_api.postman_collection.json`: `token_url`, `client_id`, `client_secret`
- Terraform: real `sqs_queue_arn`/`sqs_queue_url`, `s3_bucket_arn`, account-specific values
