"""
Lambda Handler - API Gateway -> SQS -> S3 (landing bucket)

Base URL : https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1/empatia
Endpoints: POST /details/events  |  POST /summary/events
Auth     : OAuth 2.0 Bearer token (validated by a Lambda/Cognito authorizer
           on API Gateway) - see api-docs.json for the security scheme.

S3 landing paths:
  augusta-nexa-dev/empatia/transcripciones/detalle/api/year=YYYY/month=MM/day=DD/<record_id>.json
  augusta-nexa-dev/empatia/transcripciones/resumen/api/year=YYYY/month=MM/day=DD/<record_id>.json
"""

import json
import boto3
import logging
import uuid
import os
from datetime import datetime, timezone

# -- Logging -----------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# -- AWS clients (reused across warm Lambda invocations) ----------------------
sqs = boto3.client("sqs")
s3  = boto3.client("s3")

# -- Config -- set these as Lambda Environment Variables ----------------------
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]   # e.g. https://sqs.us-east-2.amazonaws.com/123/my-queue
S3_BUCKET     = os.environ["S3_BUCKET"]       # e.g. augusta-nexa-dev

# Fixed S3 prefixes per endpoint (Hive-style partitions added at write time)
S3_BASE_PREFIXES = {
    "details": "empatia/transcripciones/detalle/api",
    "summary": "empatia/transcripciones/resumen/api",
}

VALID_ENDPOINTS = {"details", "summary"}
VALID_TIPO_PERSONA = {"Natural", "Juridica"}


# ===========================================================================
# MAIN HANDLER
# ===========================================================================

def lambda_handler(event, context):
    """
    Entry point called by API Gateway (Lambda Proxy Integration).

    event["resource"]   -> "/empatia/details/events" or "/empatia/summary/events"
    event["httpMethod"] -> "POST"
    event["body"]       -> raw JSON string sent by the client
    event["headers"]    -> includes Authorization: Bearer <token> (validated
                            upstream by the API Gateway OAuth2 authorizer)
    """

    logger.info("Received event: %s", json.dumps(event))

    # 1. Identify which endpoint was called ----------------------------------
    resource    = event.get("resource", "")
    http_method = event.get("httpMethod", "")

    if http_method != "POST":
        return _response(405, {"error": "Method Not Allowed. Use POST."})

    endpoint = _extract_endpoint(resource)
    if endpoint not in VALID_ENDPOINTS:
        return _response(404, {"error": f"Endpoint '{resource}' not found."})

    # 2. Parse the request body ------------------------------------------------
    raw_body = event.get("body") or ""

    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON in request body."})

    # 3. Validate required fields per endpoint ----------------------------------
    validation_error = _validate_payload(endpoint, payload)
    if validation_error:
        return _response(400, {"error": validation_error})

    # 4. Enrich payload with metadata --------------------------------------------
    record_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).isoformat()

    enriched = {
        "record_id":   record_id,
        "endpoint":    endpoint,          # "details" or "summary"
        "received_at": timestamp,
        "data":        payload,           # original client payload (full body)
    }

    # 5. Send to SQS ---------------------------------------------------------------
    try:
        sqs_response = sqs.send_message(
            QueueUrl    = SQS_QUEUE_URL,
            MessageBody = json.dumps(enriched, ensure_ascii=False),
            MessageAttributes={
                "endpoint": {
                    "StringValue": endpoint,
                    "DataType":    "String",
                },
                "tenant_id": {
                    "StringValue": str(payload.get("tenant_id", "unknown")),
                    "DataType":    "String",
                },
            },
        )
        logger.info("SQS MessageId: %s", sqs_response["MessageId"])
    except Exception as e:
        logger.error("SQS send failed: %s", str(e))
        return _response(500, {"error": "Failed to queue message. Try again later."})

    # 6. Write raw JSON to S3 landing bucket ----------------------------------------
    #    augusta-nexa-dev/empatia/transcripciones/detalle/api/year=2026/month=06/day=21/<record_id>.json
    now = datetime.now(timezone.utc)
    date_path = f"year={now.strftime('%Y')}/month={now.strftime('%m')}/day={now.strftime('%d')}"
    s3_key    = f"{S3_BASE_PREFIXES[endpoint]}/{date_path}/{record_id}.json"

    try:
        s3.put_object(
            Bucket      = S3_BUCKET,
            Key         = s3_key,
            Body        = json.dumps(enriched, ensure_ascii=False),
            ContentType = "application/json",
        )
        logger.info("Saved to S3: s3://%s/%s", S3_BUCKET, s3_key)
    except Exception as e:
        # SQS already received it - log S3 failure but don't fail the request
        logger.error("S3 write failed (non-fatal): %s", str(e))

    # 7. Return success ---------------------------------------------------------------
    return _response(202, {
        "message":   "Transcript received successfully.",
        "record_id": record_id,
        "endpoint":  endpoint,
        "s3_key":    s3_key,
    })


# ===========================================================================
# HELPERS
# ===========================================================================

def _extract_endpoint(resource: str) -> str:
    """
    Pulls "details" or "summary" out of a path like:
      /empatia/details/events  -> "details"
      /empatia/summary/events  -> "summary"
    """
    parts = [p for p in resource.split("/") if p]   # drop empty segments
    for p in parts:
        if p in VALID_ENDPOINTS:
            return p
    return ""


def _validate_payload(endpoint: str, payload: dict):
    """
    Returns an error string if validation fails, or None if OK.

    Shared schema for both /details and /summary (only the "data" sub-object
    differs):

      tenant_id               (required)
      idLlamada                (optional)
      tipoPersona              (required) - "Natural" | "Juridica"
      tipoIdentificacion       (required)
      numeroIdentificacion     (required)
      primerNombre             (conditionally required if tipoPersona=Natural)
      primerApellido           (conditionally required if tipoPersona=Natural)
      razonSocial              (conditionally required if tipoPersona=Juridica)
      codigoTipificacion       (required)
      descripcionTipificacion  (optional)
      fechaInicio               (optional)
      data                      (required) - shape depends on endpoint
    """
    if not isinstance(payload, dict):
        return "Payload must be a JSON object."

    # --- Fields shared by both /details and /summary -------------------------
    common_required = [
        "tenant_id",
        "tipoPersona",
        "tipoIdentificacion",
        "numeroIdentificacion",
        "codigoTipificacion",
        "data",
    ]
    missing = [f for f in common_required if f not in payload]
    if missing:
        return f"Missing required fields: {missing}"

    # --- tipoPersona enum check ------------------------------------------------
    tipo_persona = payload.get("tipoPersona")
    if tipo_persona not in VALID_TIPO_PERSONA:
        return f"Field 'tipoPersona' must be one of {sorted(VALID_TIPO_PERSONA)}"

    # --- Conditional identity fields -------------------------------------------
    if tipo_persona == "Natural":
        missing_persona = [
            f for f in ("primerNombre", "primerApellido") if not payload.get(f)
        ]
        if missing_persona:
            return (
                f"Missing required fields for tipoPersona='Natural': {missing_persona}"
            )
    elif tipo_persona == "Juridica":
        if not payload.get("razonSocial"):
            return "Missing required field for tipoPersona='Juridica': ['razonSocial']"

    # --- data sub-object ----------------------------------------------------------
    data = payload.get("data")
    if not isinstance(data, dict):
        return "Field 'data' must be a JSON object."

    if endpoint == "details":
        if "conversacion" not in data:
            return "Missing required field in 'data': 'conversacion'"

    elif endpoint == "summary":
        missing_data = [f for f in ("motivo", "resumen") if f not in data]
        if missing_data:
            return f"Missing required fields in 'data': {missing_data}"

    return None  # all good


def _response(status_code: int, body: dict) -> dict:
    """
    Builds the Lambda Proxy Integration response that API Gateway expects.
    """
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type":                "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }
