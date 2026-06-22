"""
Lambda Handler - API Gateway -> SQS -> S3 (landing bucket)

Base URL : https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1/empatia
Endpoints: POST /details/events  |  POST /summary/events
Auth     : OAuth 2.0 Bearer token (validated by a Cognito User Pools authorizer
           on API Gateway) - see api-docs.json for the security scheme.

S3 landing paths:
  augusta-nexa-dev/empatia/transcripciones/detalle/api/year=YYYY/month=MM/day=DD/<id>.json
  augusta-nexa-dev/empatia/transcripciones/resumen/api/year=YYYY/month=MM/day=DD/<id>.json
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3

# -- Logging -----------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# -- AWS clients (reused across warm Lambda invocations) ---------------------
sqs = boto3.client("sqs")
s3 = boto3.client("s3")

# -- Config -- set these as Lambda Environment Variables ---------------------
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
S3_BUCKET = os.environ["S3_BUCKET"]

# Fixed S3 prefixes per endpoint (Hive-style partitions added at write time)
S3_BASE_PREFIXES = {
    "details": "empatia/transcripciones/detalle/api",
    "summary": "empatia/transcripciones/resumen/api",
}

VALID_ENDPOINTS = {"details", "summary"}
VALID_TIPO_PERSONA = {"Natural", "Juridica"}

COMMON_REQUIRED = [
    "tenant_id",
    "tipoPersona",
    "tipoIdentificacion",
    "numeroIdentificacion",
    "codigoTipificacion",
    "data",
]


# ===========================================================================
# MAIN HANDLER
# ===========================================================================

def lambda_handler(event, context):
    """
    Entry point called by API Gateway (Lambda Proxy Integration).

    event["resource"]   -> "/empatia/details/events" or "/empatia/summary/events"
    event["httpMethod"] -> "POST"
    event["body"]       -> raw JSON string sent by the client
    event["headers"]    -> includes Authorization: Bearer <token>
    """
    logger.info("Received event: %s", json.dumps(event))

    # 1. Identify which endpoint was called
    resource = event.get("resource", "")
    http_method = event.get("httpMethod", "")

    if http_method != "POST":
        return _response(405, {"error": "Method Not Allowed. Use POST."})

    endpoint = _extract_endpoint(resource)
    if endpoint not in VALID_ENDPOINTS:
        return _response(404, {"error": f"Endpoint '{resource}' not found."})

    # 2. Parse the request body
    raw_body = event.get("body") or ""

    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON in request body."})

    # 3. Validate required fields per endpoint
    validation_error = _validate_payload(endpoint, payload)
    if validation_error:
        return _response(400, {"error": validation_error})

    # 4. Enrich payload with metadata
    record_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).isoformat()

    enriched = {
        "record_id": record_id,
        "endpoint": endpoint,
        "received_at": timestamp,
        "data": payload,
    }

    # 5. Send to SQS
    try:
        sqs_response = sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(enriched, ensure_ascii=False),
            MessageAttributes={
                "endpoint": {"StringValue": endpoint, "DataType": "String"},
                "tenant_id": {
                    "StringValue": str(payload.get("tenant_id", "unknown")),
                    "DataType": "String",
                },
            },
        )
        logger.info("SQS MessageId: %s", sqs_response["MessageId"])
    except Exception as e:
        logger.error("SQS send failed: %s", str(e))
        return _response(500, {"error": "Failed to queue message. Try again later."})

    # 6. Write raw JSON to S3 landing bucket
    now = datetime.now(timezone.utc)
    date_path = (
        f"year={now.strftime('%Y')}/month={now.strftime('%m')}/day={now.strftime('%d')}"
    )
    s3_key = f"{S3_BASE_PREFIXES[endpoint]}/{date_path}/{record_id}.json"

    try:
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=s3_key,
            Body=json.dumps(enriched, ensure_ascii=False),
            ContentType="application/json",
        )
        logger.info("Saved to S3: s3://%s/%s", S3_BUCKET, s3_key)
    except Exception as e:
        # SQS already received it — log S3 failure but don't fail the request
        logger.error("S3 write failed (non-fatal): %s", str(e))

    # 7. Return success
    return _response(202, {
        "message": "Transcript received successfully.",
        "record_id": record_id,
        "endpoint": endpoint,
        "s3_key": s3_key,
    })


# ===========================================================================
# VALIDATION  (split into small helpers to keep cyclomatic complexity low)
# ===========================================================================

def _validate_payload(endpoint: str, payload: dict):
    """
    Orchestrates validation. Returns an error string or None if OK.
    Delegates to smaller helpers so each stays under complexity threshold.
    """
    if not isinstance(payload, dict):
        return "Payload must be a JSON object."

    return (
        _validate_common_fields(payload)
        or _validate_identity_fields(payload)
        or _validate_data_object(endpoint, payload)
    )


def _validate_common_fields(payload: dict):
    """Checks that all shared required top-level fields are present."""
    missing = [f for f in COMMON_REQUIRED if f not in payload]
    if missing:
        return f"Missing required fields: {missing}"

    tipo_persona = payload.get("tipoPersona")
    if tipo_persona not in VALID_TIPO_PERSONA:
        return f"Field 'tipoPersona' must be one of {sorted(VALID_TIPO_PERSONA)}"

    return None


def _validate_identity_fields(payload: dict):
    """
    Enforces conditional identity fields based on tipoPersona:
      Natural  -> primerNombre + primerApellido required
      Juridica -> razonSocial required
    """
    tipo_persona = payload.get("tipoPersona")

    if tipo_persona == "Natural":
        missing = [
            f for f in ("primerNombre", "primerApellido") if not payload.get(f)
        ]
        if missing:
            return f"Missing required fields for tipoPersona='Natural': {missing}"

    if tipo_persona == "Juridica" and not payload.get("razonSocial"):
        return "Missing required field for tipoPersona='Juridica': ['razonSocial']"

    return None


def _validate_data_object(endpoint: str, payload: dict):
    """Validates the 'data' sub-object shape for each endpoint."""
    data = payload.get("data")
    if not isinstance(data, dict):
        return "Field 'data' must be a JSON object."

    if endpoint == "details" and "conversacion" not in data:
        return "Missing required field in 'data': 'conversacion'"

    if endpoint == "summary":
        missing = [f for f in ("motivo", "resumen") if f not in data]
        if missing:
            return f"Missing required fields in 'data': {missing}"

    return None


# ===========================================================================
# HELPERS
# ===========================================================================

def _extract_endpoint(resource: str) -> str:
    """
    Pulls 'details' or 'summary' out of a path like:
      /empatia/details/events -> 'details'
      /empatia/summary/events -> 'summary'
    """
    parts = [p for p in resource.split("/") if p]
    for p in parts:
        if p in VALID_ENDPOINTS:
            return p
    return ""


def _response(status_code: int, body: dict) -> dict:
    """Builds the Lambda Proxy Integration response API Gateway expects."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }
