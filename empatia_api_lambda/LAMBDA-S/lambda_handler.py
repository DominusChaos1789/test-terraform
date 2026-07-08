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
from urllib.parse import urlparse

import boto3
from botocore.exceptions import BotoCoreError, ClientError

# -- Logging -----------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# -- AWS clients (reused across warm Lambda invocations) ---------------------
sqs = boto3.client("sqs")
s3 = boto3.client("s3")

# -- Config -- set these as Lambda Environment Variables ---------------------
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
S3_BUCKET = os.environ["S3_BUCKET"]
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "https://empatia.example.com")

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

# Reject bodies larger than this to limit memory/DoS exposure (bytes)
MAX_BODY_BYTES = 256 * 1024  # 256 KB

# Max length accepted for the tenant_id used as an SQS message attribute
MAX_TENANT_ID_LEN = 128

# -- Conversation-URL fetch config -------------------------------------------
# For /details, `data.conversacion` arrives as a presigned S3 HTTPS URL. The
# handler downloads the object and replaces the URL with the actual text.
#
# SSRF protection: only fetch from hostnames that are genuine S3 endpoints.
# This still accepts presigned URLs from ANY bucket — it only blocks non-S3
# hosts (e.g. the instance metadata endpoint). To widen the allowlist later,
# add suffixes to ALLOWED_URL_HOST_SUFFIXES below.
ALLOWED_URL_HOST_SUFFIXES = (
    ".amazonaws.com",  # covers *.s3.amazonaws.com and *.s3.<region>.amazonaws.com
)

# Cap the size of a fetched conversation to protect memory / SQS limits (bytes)
MAX_FETCH_BYTES = 200 * 1024  # 200 KB


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
    # Log only non-user-controlled metadata to avoid log injection (S5145)
    logger.info(
        "Received event: resource=%s method=%s",
        event.get("resource", ""),
        event.get("httpMethod", ""),
    )

    # 1-3. Route + parse + validate (returns (endpoint, payload) or an error response)
    endpoint, payload, error_response = _parse_request(event)
    if error_response is not None:
        return error_response

    # 3b. For /details, resolve the conversacion URL into the actual text.
    # On any failure the original URL is kept (non-fatal) and the failure logged.
    if endpoint == "details":
        _resolve_conversacion(payload)

    # 4. Enrich payload with metadata
    record_id = str(uuid.uuid4())
    enriched = {
        "record_id": record_id,
        "endpoint": endpoint,
        "received_at": datetime.now(timezone.utc).isoformat(),
        "data": payload,
    }
    serialized = json.dumps(enriched, ensure_ascii=False)

    # 5. Send to SQS (specific AWS exceptions only — S112)
    try:
        sqs_response = sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=serialized,
            MessageAttributes={
                "endpoint": {"StringValue": endpoint, "DataType": "String"},
                "tenant_id": {
                    "StringValue": _safe_tenant_id(payload.get("tenant_id")),
                    "DataType": "String",
                },
            },
        )
        logger.info("SQS MessageId: %s", sqs_response["MessageId"])
    except (BotoCoreError, ClientError) as e:
        logger.error("SQS send failed: %s", e)
        return _response(500, {"error": "Failed to queue message. Try again later."})

    # 6. Write raw JSON to S3 landing bucket (non-fatal on failure)
    s3_key = _build_s3_key(endpoint, record_id)
    _write_to_s3(s3_key, serialized)

    # 7. Return success
    # Note: s3_key is intentionally NOT returned — internal storage paths
    # should not be exposed to API callers.
    return _response(202, {
        "message": "Transcript received successfully.",
        "record_id": record_id,
        "endpoint": endpoint,
    })


def _parse_request(event):
    """
    Handles routing, body-size limiting, JSON parsing, and validation.

    Returns a tuple (endpoint, payload, error_response):
      - on success: (endpoint, payload, None)
      - on failure: (None, None, <Lambda response dict>)
    """
    if event.get("httpMethod", "") != "POST":
        return None, None, _response(405, {"error": "Method Not Allowed. Use POST."})

    resource = event.get("resource", "")
    endpoint = _extract_endpoint(resource)
    if endpoint not in VALID_ENDPOINTS:
        return None, None, _response(404, {"error": f"Endpoint '{resource}' not found."})

    raw_body = event.get("body") or ""
    if len(raw_body.encode("utf-8")) > MAX_BODY_BYTES:
        return None, None, _response(413, {"error": "Request body too large."})

    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError:
        return None, None, _response(400, {"error": "Invalid JSON in request body."})

    validation_error = _validate_payload(endpoint, payload)
    if validation_error:
        return None, None, _response(400, {"error": validation_error})

    return endpoint, payload, None


def _build_s3_key(endpoint: str, record_id: str) -> str:
    """Builds the Hive-partitioned S3 key for the given endpoint."""
    now = datetime.now(timezone.utc)
    date_path = (
        f"year={now.strftime('%Y')}/month={now.strftime('%m')}/day={now.strftime('%d')}"
    )
    return f"{S3_BASE_PREFIXES[endpoint]}/{date_path}/{record_id}.json"


def _write_to_s3(s3_key: str, serialized: str) -> None:
    """Writes the record to S3. Failure is non-fatal (SQS already has it)."""
    try:
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=s3_key,
            Body=serialized,
            ContentType="application/json",
        )
        logger.info("Saved to S3: s3://%s/%s", S3_BUCKET, s3_key)
    except (BotoCoreError, ClientError) as e:
        logger.error("S3 write failed (non-fatal): %s", e)


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
# CONVERSATION URL RESOLUTION  (fetch presigned S3 URL -> replace with text)
# ===========================================================================

def _resolve_conversacion(payload: dict) -> None:
    """
    If data.conversacion is an S3 URL, download the object and replace the URL
    with the actual conversation text. Mutates payload in place.

    All failures are non-fatal: the original URL is kept and the error logged,
    so the request still succeeds (per requirements).
    """
    data = payload.get("data")
    if not isinstance(data, dict):
        return

    url = data.get("conversacion")
    if not isinstance(url, str) or not url.lower().startswith("https://"):
        # Not a URL (already inline text, or empty) — nothing to resolve
        return

    text = _fetch_url_text(url)
    if text is not None:
        data["conversacion"] = text


def _fetch_url_text(url: str):
    """
    Downloads text from a presigned S3 URL. Returns the text, or None on any
    failure (caller keeps the original URL).

    SSRF guard: only fetch from allowed S3 hostnames.
    """
    host = urlparse(url).hostname or ""
    if not host.endswith(ALLOWED_URL_HOST_SUFFIXES):
        logger.warning("Refusing to fetch conversacion from non-S3 host")
        return None

    parsed = urlparse(url)
    if parsed.scheme != "https":
        logger.warning("Refusing to fetch conversacion with non-https scheme")
        return None

    # Import here so the module has no hard dependency if fetching is unused
    import urllib.request

    try:
        with urllib.request.urlopen(url, timeout=5) as resp:  # nosec B310  # noqa: S310
            raw = resp.read(MAX_FETCH_BYTES + 1)
    except (OSError, ValueError) as e:
        logger.error("Failed to fetch conversacion URL: %s", e)
        return None

    if len(raw) > MAX_FETCH_BYTES:
        logger.error("Fetched conversacion exceeds max size; keeping URL")
        return None

    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-8", errors="replace")


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


def _safe_tenant_id(value) -> str:
    """
    Sanitizes the user-supplied tenant_id before it is used as an SQS
    message attribute. Coerces to string and bounds the length.
    """
    text = str(value) if value is not None else "unknown"
    return text[:MAX_TENANT_ID_LEN]


def _response(status_code: int, body: dict) -> dict:
    """Builds the Lambda Proxy Integration response API Gateway expects."""
    # Restrict CORS to a specific origin via env var — wildcard (*) is a
    # security vulnerability (SonarQube S5122) on an authenticated API.
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
            "X-Content-Type-Options": "nosniff",
            "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }
