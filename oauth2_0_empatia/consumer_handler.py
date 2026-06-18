"""
consumer_handler.py

Lambda function triggered by the SQS queue.
Reads each message (originally sent by ingestion_handler.py), and writes
the JSON payload to the "landing" S3 bucket using Hive-style partitioning,
so Athena/Glue Crawler can pick it up cleanly later (same pattern you're
already using for cariai-batch-extractor).

S3 key layout produced by this function:

    transacciones/empatia/transcripciones/detalle/
        tenant_id=<tenant_id>/
        anio=<YYYY>/mes=<MM>/dia=<DD>/
        <conversacion_id>_<message_id>.json

    transacciones/empatia/transcripciones/resumen/
        tenant_id=<tenant_id>/
        anio=<YYYY>/mes=<MM>/dia=<DD>/
        <conversacion_id>_<message_id>.json

Partitioning by tenant_id/anio/mes/dia keeps Athena partition pruning cheap,
and matches the "fecha_creacion" semantics you're already using upstream.
Adjust the partition keys below if you'd rather partition only by date.
"""

import json
import logging
import os
from datetime import datetime

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

LANDING_BUCKET = os.environ["LANDING_BUCKET"]

# Base prefix per endpoint. Matches what you described:
# "transacciones/empatia/transcripciones/<endpoint>/"
BASE_PREFIXES = {
    "detalle": "transacciones/empatia/transcripciones/detalle",
    "resumen": "transacciones/empatia/transcripciones/resumen",
}


def _parse_fecha_creacion(fecha_creacion: str, fallback_iso: str) -> datetime:
    """
    Tries to parse the client-provided fecha_creacion field for partitioning.
    Falls back to the time the message was received (set by the ingestion
    Lambda) if fecha_creacion is missing or in an unexpected format, so a bad
    or empty fecha_creacion does not throw away the whole message.
    """
    candidates = [fecha_creacion]
    formats = ["%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"]

    for value in candidates:
        if not value:
            continue
        for fmt in formats:
            try:
                return datetime.strptime(value, fmt)
            except ValueError:
                continue

    # Fallback: when the message was received by the ingestion Lambda
    return datetime.fromisoformat(fallback_iso)


def _build_s3_key(payload: dict) -> str:
    metadata = payload.get("_metadata", {})
    endpoint = metadata.get("endpoint")
    message_id = metadata.get("message_id", "unknown")
    received_at = metadata.get("received_at")

    if endpoint not in BASE_PREFIXES:
        raise ValueError(f"Unknown endpoint in message metadata: {endpoint}")

    tenant_id = payload.get("tenant_id", "unknown_tenant")
    conversacion_id = payload.get("conversacion_id", "unknown_conv")

    fecha = _parse_fecha_creacion(payload.get("fecha_creacion", ""), received_at)

    partition_path = (
        f"tenant_id={tenant_id}/"
        f"anio={fecha.year:04d}/mes={fecha.month:02d}/dia={fecha.day:02d}"
    )

    file_name = f"{conversacion_id}_{message_id}.json"

    return f"{BASE_PREFIXES[endpoint]}/{partition_path}/{file_name}"


def lambda_handler(event, context):
    """
    SQS triggers this with a batch of records in event['Records'].
    We process each independently and report partial failures back to SQS
    (via batchItemFailures) so only the failed messages get retried/DLQ'd,
    not the whole batch.
    """
    batch_item_failures = []

    for record in event.get("Records", []):
        message_id_sqs = record["messageId"]
        try:
            payload = json.loads(record["body"])
            key = _build_s3_key(payload)

            s3.put_object(
                Bucket=LANDING_BUCKET,
                Key=key,
                Body=json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8"),
                ContentType="application/json",
            )

            logger.info("Wrote s3://%s/%s", LANDING_BUCKET, key)

        except Exception:
            logger.exception("Failed to process SQS message %s", message_id_sqs)
            batch_item_failures.append({"itemIdentifier": message_id_sqs})

    # Returning this shape requires "Report batch item failures" to be
    # enabled on the SQS event source mapping (set in Terraform).
    return {"batchItemFailures": batch_item_failures}
