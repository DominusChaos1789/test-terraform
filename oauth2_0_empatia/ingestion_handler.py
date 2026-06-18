"""
ingestion_handler.py

Lambda function behind API Gateway for the "empatia" API.
Handles BOTH endpoints:
    POST /detalle/events/
    POST /resumen/events/

Responsibilities (kept intentionally light, since this runs on the
synchronous request path and the client is waiting on a response):
    1. Identify which endpoint was called (detalle vs resumen).
    2. Validate that the JSON body has the required fields for that endpoint.
    3. Send the validated payload to SQS (one message per request).
    4. Return a fast 2xx/4xx response to the client.

NOTE on auth:
    OAuth2.0 token validation is handled by the API Gateway authorizer
    (Cognito or Lambda authorizer) BEFORE this function ever runs.
    This handler does not need to check tokens — if the request reached
    here, API Gateway already approved it. If you ever need to read
    claims from the validated token (e.g. to know which client called),
    they show up in:
        event['requestContext']['authorizer']
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs = boto3.client("sqs")

QUEUE_URL = os.environ["QUEUE_URL"]  # set via Terraform/env var

# Fields every payload must have, regardless of endpoint
COMMON_REQUIRED_FIELDS = [
    "tenant_id",
    "conversacion_id",
    "tipo_documento",
    "numero_documento",
    "numero_telefono",
    "tipo_producto",
    "tipo",
    "fecha_creacion",
    "data",
]

# Fields required inside "data", per endpoint
DATA_REQUIRED_FIELDS = {
    "detalle": ["conversacion"],
    "resumen": ["motivo", "resumen"],
}


def _build_response(status_code: int, body: dict) -> dict:
    """API Gateway (Lambda proxy integration) expects this exact shape."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def _identify_endpoint(event: dict) -> str:
    """
    Works out whether this request came from /detalle/events/ or
    /resumen/events/. We check the resource path rather than trusting
    the body's "tipo" field, so a mismatched body gets caught by validation
    instead of silently being filed under the wrong endpoint.
    """
    path = event.get("path") or event.get("rawPath") or ""
    path = path.lower()

    if "detalle" in path:
        return "detalle"
    if "resumen" in path:
        return "resumen"

    # Fallback for safety, shouldn't happen if API Gateway routes are
    # configured correctly with one resource per endpoint.
    raise ValueError(f"Could not determine endpoint from path: {path}")


def _validate_payload(payload: dict, endpoint: str) -> list:
    """
    Returns a list of human-readable error strings.
    Empty list means the payload is valid.
    """
    errors = []

    for field in COMMON_REQUIRED_FIELDS:
        if field not in payload or payload[field] in (None, ""):
            errors.append(f"Missing or empty required field: '{field}'")

    # "tipo" must match the endpoint that was called
    expected_tipo = endpoint  # "detalle" -> "conversacion" is special-cased below
    if endpoint == "detalle" and payload.get("tipo") != "conversacion":
        errors.append("Field 'tipo' must be 'conversacion' for the /detalle endpoint")
    elif endpoint == "resumen" and payload.get("tipo") != "resumen":
        errors.append("Field 'tipo' must be 'resumen' for the /resumen endpoint")

    data = payload.get("data")
    if not isinstance(data, dict):
        errors.append("Field 'data' must be a JSON object")
    else:
        for field in DATA_REQUIRED_FIELDS[endpoint]:
            if field not in data or data[field] in (None, ""):
                errors.append(f"Missing or empty required field in 'data': '{field}'")

    return errors


def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event)[:2000])  # truncate for log size

    # 1. Work out which endpoint we're handling
    try:
        endpoint = _identify_endpoint(event)
    except ValueError as e:
        logger.error(str(e))
        return _build_response(400, {"error": str(e)})

    # 2. Parse the body (API Gateway proxy integration sends it as a string)
    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64

        raw_body = base64.b64decode(raw_body).decode("utf-8")

    try:
        payload = json.loads(raw_body)
    except (json.JSONDecodeError, TypeError):
        logger.error("Body is not valid JSON")
        return _build_response(400, {"error": "Request body must be valid JSON"})

    # 3. Validate required fields for this endpoint
    validation_errors = _validate_payload(payload, endpoint)
    if validation_errors:
        logger.warning("Validation failed: %s", validation_errors)
        return _build_response(400, {"error": "Validation failed", "details": validation_errors})

    # 4. Enrich the message with metadata the consumer Lambda will need
    #    to build the S3 partition path (Hive-style) without having to
    #    re-derive it.
    now_utc = datetime.now(timezone.utc)
    message_id = str(uuid.uuid4())

    enriched_payload = {
        **payload,
        "_metadata": {
            "endpoint": endpoint,           # "detalle" or "resumen"
            "received_at": now_utc.isoformat(),
            "message_id": message_id,
        },
    }

    # 5. Send to SQS. SQS is the hand-off point — once this succeeds,
    #    we can return 202 to the client immediately. The consumer
    #    Lambda picks it up asynchronously and writes to S3.
    try:
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(enriched_payload, ensure_ascii=False),
            MessageAttributes={
                "endpoint": {"DataType": "String", "StringValue": endpoint},
                "tenant_id": {"DataType": "String", "StringValue": str(payload["tenant_id"])},
            },
        )
    except Exception:
        logger.exception("Failed to send message to SQS")
        return _build_response(502, {"error": "Failed to queue message, please retry"})

    logger.info("Queued message %s for endpoint '%s'", message_id, endpoint)

    return _build_response(
        202,
        {
            "message": "Accepted",
            "message_id": message_id,
            "endpoint": endpoint,
        },
    )
