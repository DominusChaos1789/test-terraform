# Empatia API — Architecture & Handlers

## Flow

```
Client (OAuth2.0 token)
   |
   v
API Gateway  --(Cognito / Lambda authorizer validates token)-->
   |
   |-- POST /detalle/events/  ---\
   |-- POST /resumen/events/  ---+--> ingestion_handler.py (Lambda)
                                       |
                                       | validates JSON body per endpoint
                                       v
                                     SQS queue
                                       |
                                       | triggers
                                       v
                              consumer_handler.py (Lambda)
                                       |
                                       v
                          S3 "landing" bucket (Hive-partitioned JSON)
```

Two Lambdas, one queue:

1. **`ingestion_handler.py`** — sits behind API Gateway. Runs synchronously
   while the client waits. It does the minimum needed to respond fast:
   figures out which endpoint was hit, checks the JSON body has the right
   fields, drops the message on SQS, returns `202 Accepted`.
2. **`consumer_handler.py`** — triggered asynchronously by SQS (not by API
   Gateway). It reads each message and writes it to S3 as a JSON file under
   a Hive-style partitioned path, ready for a Glue Crawler / Athena.

Splitting it this way means a slow or failing S3 write never makes the
client's HTTP request hang, and SQS gives you automatic retries + a
dead-letter queue for messages that fail repeatedly.

## Why the Lambda doesn't touch OAuth2.0 directly

You said API Gateway already validates the token via an authorizer
(Cognito User Pool authorizer or a Lambda authorizer) before the request
reaches `ingestion_handler.py`. That means:

- If the token is invalid/expired, API Gateway rejects with `401` before
  your Lambda ever runs — you don't pay for that invocation.
- Inside `ingestion_handler.py`, if you ever need info about who called
  (e.g. client ID from the token claims), it'll be available at
  `event['requestContext']['authorizer']`. Not used in the current code
  since you said simple validation is enough for now.

## Request bodies

**`/detalle/events/`** — `tipo` must be `"conversacion"`, `data` must
contain `conversacion`:

```json
{
    "tenant_id": "abc123",
    "conversacion_id": "conv-001",
    "tipo_documento": "CC",
    "numero_documento": "123456789",
    "numero_telefono": "3001234567",
    "tipo_producto": "credito",
    "tipo": "conversacion",
    "fecha_creacion": "2026-06-17T10:30:00",
    "data": {
        "conversacion": "full transcript text here..."
    }
}
```

**`/resumen/events/`** — `tipo` must be `"resumen"`, `data` must contain
`motivo` and `resumen`:

```json
{
    "tenant_id": "abc123",
    "conversacion_id": "conv-001",
    "tipo_documento": "CC",
    "numero_documento": "123456789",
    "numero_telefono": "3001234567",
    "tipo_producto": "credito",
    "tipo": "resumen",
    "fecha_creacion": "2026-06-17T10:30:00",
    "data": {
        "motivo": "consulta de saldo",
        "resumen": "summary text here..."
    }
}
```

Both go through the same validation pattern; the difference is just which
fields are required inside `data`, defined in `DATA_REQUIRED_FIELDS` in
`ingestion_handler.py`. If the body's `tipo` field doesn't match the
endpoint that was called (e.g. someone POSTs `"tipo": "resumen"` to
`/detalle/events/`), the request is rejected with `400` — this catches
copy-paste mistakes from client-side integrators early.

## Responses

- `202 Accepted` — message validated and queued successfully.
- `400 Bad Request` — body isn't JSON, or required fields are missing/empty,
  or `tipo` doesn't match the endpoint. Response includes a `details` list
  of every problem found, not just the first one.
- `502 Bad Gateway` — SQS send failed (rare; transient AWS issue). Client
  should retry.

## S3 output layout

Based on what you described, the consumer writes here:

```
s3://<landing-bucket>/transacciones/empatia/transcripciones/detalle/
    tenant_id=<tenant_id>/anio=2026/mes=06/dia=17/<conversacion_id>_<message_id>.json

s3://<landing-bucket>/transacciones/empatia/transcripciones/resumen/
    tenant_id=<tenant_id>/anio=2026/mes=06/dia=17/<conversacion_id>_<message_id>.json
```

`anio=/mes=/dia=` is the standard Hive partition naming Glue Crawler and
Athena expect (`key=value` folder segments). Partitioning by `tenant_id`
first, then date, keeps queries scoped to one client cheap. If you'd rather
partition only by date (no tenant_id level), just drop that segment in
`_build_s3_key()` in `consumer_handler.py` — one line to change.

The date used for partitioning is parsed from the client's
`fecha_creacion` field. If it's missing or in an unexpected format, it
falls back to the timestamp the ingestion Lambda stamped on receipt
(`_metadata.received_at`), so a malformed date never causes a dropped
message.

## Environment variables expected

| Lambda | Variable | Purpose |
|---|---|---|
| `ingestion_handler.py` | `QUEUE_URL` | SQS queue URL to send messages to |
| `consumer_handler.py` | `LANDING_BUCKET` | S3 bucket name (`landing`) |

## IAM permissions needed

- **Ingestion Lambda role**: `sqs:SendMessage` on the queue ARN, plus
  standard `AWSLambdaBasicExecutionRole` for CloudWatch logs.
- **Consumer Lambda role**: `sqs:ReceiveMessage`, `sqs:DeleteMessage`,
  `sqs:GetQueueAttributes` on the queue ARN; `s3:PutObject` on the landing
  bucket's `transacciones/empatia/transcripciones/*` prefix; standard
  basic execution role.

## Terraform module plan

Suggested module breakdown — mirrors how you've structured
`cariai-batch-extractor`, so it should feel familiar:

```
modules/
  api_gateway/
    main.tf        # REST API, resources (/detalle/events, /resumen/events),
                    # POST methods, Lambda proxy integration, deployment + stage
    authorizer.tf   # Cognito or Lambda authorizer resource, attached to both methods
    variables.tf
    outputs.tf      # invoke_url, api_id

  lambda_ingestion/
    main.tf        # aws_lambda_function (ingestion_handler.py), env vars, IAM role/policy
    variables.tf
    outputs.tf      # lambda_arn, lambda_invoke_arn (needed by api_gateway module)

  lambda_consumer/
    main.tf        # aws_lambda_function (consumer_handler.py), env vars, IAM role/policy
                    # aws_lambda_event_source_mapping (SQS trigger, batch size,
                    # function_response_types = ["ReportBatchItemFailures"])
    variables.tf
    outputs.tf

  sqs/
    main.tf        # aws_sqs_queue (main) + aws_sqs_queue (DLQ) + redrive policy
    variables.tf
    outputs.tf      # queue_url, queue_arn, dlq_arn

  s3_landing/
    main.tf        # references existing "landing" bucket, or creates it,
                    # plus bucket policy allowing consumer Lambda role to PutObject
                    # under transacciones/empatia/transcripciones/*
    variables.tf
    outputs.tf

  waf/
    main.tf        # aws_wafv2_web_acl + association with the API Gateway stage
                    # (you mentioned you already have this — just wire the
                    # association if not already done)
    variables.tf
```

Root module (`environments/dev-1/main.tf` or similar) wires them together:

```hcl
module "sqs" {
  source = "../../modules/sqs"
  queue_name = "empatia-events-queue"
}

module "lambda_consumer" {
  source         = "../../modules/lambda_consumer"
  landing_bucket = module.s3_landing.bucket_name
  sqs_queue_arn  = module.sqs.queue_arn
  sqs_queue_url  = module.sqs.queue_url
}

module "lambda_ingestion" {
  source     = "../../modules/lambda_ingestion"
  queue_url  = module.sqs.queue_url
  queue_arn  = module.sqs.queue_arn
}

module "api_gateway" {
  source                = "../../modules/api_gateway"
  ingestion_lambda_arn  = module.lambda_ingestion.lambda_invoke_arn
  stage_name            = "dev-1"
  authorizer_type       = "COGNITO_USER_POOLS"  # or "TOKEN" for a Lambda authorizer
  cognito_user_pool_arn = var.cognito_user_pool_arn
}

module "waf" {
  source      = "../../modules/waf"
  api_gateway_stage_arn = module.api_gateway.stage_arn
}
```

A few things worth deciding before you write the Terraform:

- **Authorizer type** — Cognito User Pool authorizer is less code (no
  Lambda to maintain) if the client already has a Cognito user pool issuing
  the OAuth2.0 tokens. A Lambda authorizer gives you more control (e.g.
  validating against a third-party IdP) but is one more function to test
  and monitor.
- **DLQ redrive count** — how many SQS delivery attempts before a message
  goes to the dead-letter queue. 3–5 is typical.
- **Lambda batch size on the SQS trigger** — start small (1–5) until you've
  confirmed `_build_s3_key` and the put_object call behave the way you
  expect under load, then increase for throughput.
