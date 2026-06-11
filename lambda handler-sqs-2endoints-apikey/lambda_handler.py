"""
Lambda Handler - API Gateway → SQS → S3 (landing bucket)
Endpoints: POST /details  |  POST /summary
Auth: API Key via x-api-key header (managed by API Gateway)

Flow:
  Client → API Gateway (WAF + API Key) → Lambda → SQS → (consumer) → S3 landing
  Note: This Lambda also writes directly to S3 as a backup/audit trail.
"""

import json
import boto3
import logging
import uuid
from datetime import datetime, timezone

# ── Logging ──────────────────────────────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── AWS clients (reused across warm Lambda invocations) ───────────────────────
sqs = boto3.client("sqs")
s3  = boto3.client("s3")

# ── Config — set these as Lambda Environment Variables ────────────────────────
import os
SQS_QUEUE_URL   = os.environ["SQS_QUEUE_URL"]    # e.g. https://sqs.us-east-1.amazonaws.com/123/my-queue
S3_BUCKET       = os.environ["S3_BUCKET"]         # e.g. landing
S3_PREFIX       = os.environ.get("S3_PREFIX", "transcripts")  # optional prefix

# ── Allowed endpoints ─────────────────────────────────────────────────────────
VALID_ENDPOINTS = {"details", "summary"}


# =============================================================================
# MAIN HANDLER
# =============================================================================

def lambda_handler(event, context):
    """
    Entry point called by API Gateway (Lambda Proxy Integration).

    API Gateway passes:
      event["resource"]      -> "/details" or "/summary"
      event["httpMethod"]    -> "POST"
      event["body"]          -> raw JSON string sent by the client
      event["headers"]       -> includes x-api-key (already validated by APIGW)
    """

    logger.info("Received event: %s", json.dumps(event))

    # 1. Identify which endpoint was called
    resource    = event.get("resource", "").strip("/")   # "details" or "summary"
    http_method = event.get("httpMethod", "")

    if http_method != "POST":
        return _response(405, {"error": "Method Not Allowed. Use POST."})

    if resource not in VALID_ENDPOINTS:
        return _response(404, {"error": f"Endpoint '/{resource}' not found."})

    # 2. Parse the request body
    raw_body = event.get("body") or ""

    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON in request body."})

    # 3. Validate required fields per endpoint
    validation_error = _validate_payload(resource, payload)
    if validation_error:
        return _response(400, {"error": validation_error})

    # 4. Enrich payload with metadata
    record_id  = str(uuid.uuid4())
    timestamp  = datetime.now(timezone.utc).isoformat()

    enriched = {
        "record_id":   record_id,
        "endpoint":    resource,          # "details" or "summary"
        "received_at": timestamp,
        "data":        payload,           # original client payload
    }

    # 5. Send to SQS
    try:
        sqs_response = sqs.send_message(
            QueueUrl    = SQS_QUEUE_URL,
            MessageBody = json.dumps(enriched),
            MessageAttributes={
                "endpoint": {
                    "StringValue": resource,
                    "DataType":    "String",
                },
            },
        )
        logger.info("SQS MessageId: %s", sqs_response["MessageId"])
    except Exception as e:
        logger.error("SQS send failed: %s", str(e))
        return _response(500, {"error": "Failed to queue message. Try again later."})

    # 6. Write raw JSON to S3 landing bucket
    #    S3 key pattern:  transcripts/details/2025/06/11/<record_id>.json
    date_path = datetime.now(timezone.utc).strftime("%Y/%m/%d")
    s3_key    = f"{S3_PREFIX}/{resource}/{date_path}/{record_id}.json"

    try:
        s3.put_object(
            Bucket      = S3_BUCKET,
            Key         = s3_key,
            Body        = json.dumps(enriched, ensure_ascii=False),
            ContentType = "application/json",
        )
        logger.info("Saved to S3: s3://%s/%s", S3_BUCKET, s3_key)
    except Exception as e:
        # SQS already received it — log S3 failure but don't fail the request
        logger.error("S3 write failed (non-fatal): %s", str(e))

    # 7. Return success
    return _response(202, {
        "message":   "Transcript received successfully.",
        "record_id": record_id,
        "endpoint":  resource,
        "s3_key":    s3_key,
    })


# =============================================================================
# HELPERS
# =============================================================================

def _validate_payload(endpoint: str, payload: dict):
    """
    Returns an error string if validation fails, or None if OK.
    Adjust required fields to match what your client actually sends.
    """
    if not isinstance(payload, dict):
        return "Payload must be a JSON object."

    if endpoint == "details":
        # Expected fields for a full conversation transcript
        required = ["conversation_id", "transcript", "agent_id"]
        missing  = [f for f in required if f not in payload]
        if missing:
            return f"Missing required fields for /details: {missing}"

    elif endpoint == "summary":
        # Expected fields for a summarised conversation
        required = ["conversation_id", "summary_text"]
        missing  = [f for f in required if f not in payload]
        if missing:
            return f"Missing required fields for /summary: {missing}"

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
        "body": json.dumps(body),
    }
