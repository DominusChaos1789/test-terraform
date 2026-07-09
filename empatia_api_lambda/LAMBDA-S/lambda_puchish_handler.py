"""
Lambda handler: triggered by S3 ObjectCreated events (replicated JSON files),
validates the payload, obtains an OAuth2 client-credentials token, and POSTs
the payload to a configurable downstream API endpoint.

Design notes
------------
- The API endpoint and token URL are read from SSM Parameter Store at
  invocation time (not baked into env vars at deploy time) so they can
  change without a redeploy.
- Client id / secret live in Secrets Manager, never in plaintext env vars.
- An explicit host allowlist protects against SSRF if the SSM parameter
  is ever misconfigured or tampered with.
- The access token is cached in a module-level dict so warm Lambda
  containers reuse it until it is close to expiry.
- Retries with backoff on transient HTTP failures; a 401 triggers one
  forced token refresh before giving up.
"""

import json
import logging
import os
import re
import time
import urllib.parse
from typing import Any, Dict, List, Optional

import boto3
import requests

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

s3_client = boto3.client("s3")
secrets_client = boto3.client("secretsmanager")
ssm_client = boto3.client("ssm")

# NOTE: this mirrors the schema's "required" array exactly. The schema's
# "properties" block defines "idLlamada" (not "idCall") -- that mismatch
# is in the source schema, not introduced here. Confirm with the client
# which field name is authoritative.
REQUIRED_FIELDS = [
    "tenant_id",
    "idCall",
    "tipoPersona",
    "tipoIdentificacion",
    "numeroIdentificacion",
    "codigoTipificacion",
]

VALID_TIPO_PERSONA = {"Natural", "Juridica"}

MAX_BODY_SIZE_BYTES = int(os.environ.get("MAX_BODY_SIZE_BYTES", 1_000_000))
HTTP_TIMEOUT_SECONDS = int(os.environ.get("HTTP_TIMEOUT_SECONDS", 10))
TOKEN_CACHE_SKEW_SECONDS = 30

_token_cache: Dict[str, Any] = {"access_token": None, "expires_at": 0}


class ValidationError(Exception):
    """Raised when the incoming payload fails schema/business validation."""


class ConfigError(Exception):
    """Raised when required configuration (SSM/Secrets) is missing or unsafe."""


def _get_secret(secret_id: str) -> Dict[str, str]:
    resp = secrets_client.get_secret_value(SecretId=secret_id)
    return json.loads(resp["SecretString"])


def _get_ssm_param(name: str, decrypt: bool = False) -> str:
    resp = ssm_client.get_parameter(Name=name, WithDecryption=decrypt)
    return resp["Parameter"]["Value"]


def _is_allowed_endpoint(url: str, allowed_hosts: List[str]) -> bool:
    """SSRF guard: require https and an explicit host allowlist."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        return False
    if not parsed.hostname:
        return False
    return parsed.hostname.lower() in allowed_hosts


def _sanitize_tenant_id(tenant_id: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", tenant_id or ""):
        raise ValidationError("Invalid tenant_id format")
    return tenant_id


def reset_token_cache() -> None:
    """Exposed mainly for tests; forces the next call to fetch a new token."""
    _token_cache["access_token"] = None
    _token_cache["expires_at"] = 0


def _get_access_token(
    token_url: str, client_id: str, client_secret: str, scope: Optional[str] = None
) -> str:
    now = time.time()
    if _token_cache["access_token"] and now < _token_cache["expires_at"] - TOKEN_CACHE_SKEW_SECONDS:
        return _token_cache["access_token"]

    data = {"grant_type": "client_credentials"}
    if scope:
        data["scope"] = scope

    resp = requests.post(
        token_url,
        data=data,
        auth=(client_id, client_secret),
        timeout=HTTP_TIMEOUT_SECONDS,
    )
    resp.raise_for_status()
    body = resp.json()

    access_token = body["access_token"]
    expires_in = int(body.get("expires_in", 3600))

    _token_cache["access_token"] = access_token
    _token_cache["expires_at"] = now + expires_in
    return access_token


def validate_payload(payload: Dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise ValidationError("Payload must be a JSON object")

    missing = [f for f in REQUIRED_FIELDS if payload.get(f) in (None, "")]
    if missing:
        raise ValidationError(f"Missing required fields: {', '.join(missing)}")

    if payload.get("tipoPersona") not in VALID_TIPO_PERSONA:
        raise ValidationError(f"tipoPersona must be one of {sorted(VALID_TIPO_PERSONA)}")

    _sanitize_tenant_id(payload["tenant_id"])


def _read_s3_object(bucket: str, key: str) -> Dict[str, Any]:
    resp = s3_client.get_object(Bucket=bucket, Key=key)
    body = resp["Body"].read(MAX_BODY_SIZE_BYTES + 1)
    if len(body) > MAX_BODY_SIZE_BYTES:
        raise ValidationError("Object exceeds max allowed size")
    return json.loads(body)


def _post_with_retry(
    url: str, headers: Dict[str, str], payload: Dict[str, Any], max_attempts: int = 3
) -> requests.Response:
    last_exc: Optional[Exception] = None
    for attempt in range(1, max_attempts + 1):
        try:
            resp = requests.post(url, json=payload, headers=headers, timeout=HTTP_TIMEOUT_SECONDS)
            if resp.status_code == 401 and attempt < max_attempts:
                reset_token_cache()
                continue
            resp.raise_for_status()
            return resp
        except requests.RequestException as exc:
            last_exc = exc
            if attempt < max_attempts:
                time.sleep(min(2 ** attempt, 8))
                continue
    assert last_exc is not None
    raise last_exc


def _load_config() -> Dict[str, Any]:
    endpoint_param = os.environ["ENDPOINT_SSM_PARAM"]
    token_url_param = os.environ["TOKEN_URL_SSM_PARAM"]
    secret_id = os.environ["API_CREDENTIALS_SECRET_ID"]
    allowed_hosts_raw = os.environ.get("ALLOWED_ENDPOINT_HOSTS", "")
    allowed_hosts = [h.strip().lower() for h in allowed_hosts_raw.split(",") if h.strip()]

    endpoint_url = _get_ssm_param(endpoint_param)
    token_url = _get_ssm_param(token_url_param)

    if not _is_allowed_endpoint(endpoint_url, allowed_hosts):
        raise ConfigError(f"Endpoint host not in allowlist: {endpoint_url}")

    creds = _get_secret(secret_id)
    if "client_id" not in creds or "client_secret" not in creds:
        raise ConfigError("Secret is missing client_id/client_secret")

    return {
        "endpoint_url": endpoint_url,
        "token_url": token_url,
        "client_id": creds["client_id"],
        "client_secret": creds["client_secret"],
        "scope": creds.get("scope"),
    }


def process_record(record: Dict[str, Any]) -> Dict[str, Any]:
    bucket = record["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

    payload = _read_s3_object(bucket, key)
    validate_payload(payload)

    config = _load_config()
    token = _get_access_token(
        config["token_url"], config["client_id"], config["client_secret"], config["scope"]
    )

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "X-Tenant-Id": payload["tenant_id"],
    }

    response = _post_with_retry(config["endpoint_url"], headers, payload)
    return {"bucket": bucket, "key": key, "status_code": response.status_code}


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Entry point for direct S3 -> Lambda event notifications.

    If you move to S3 -> SQS -> Lambda (recommended for retry/DLQ control,
    see the Terraform notes), switch this to report batchItemFailures
    instead of raising, so only the failed messages are retried.
    """
    results = []
    errors = []

    for record in event.get("Records", []):
        key_for_log = record.get("s3", {}).get("object", {}).get("key")
        try:
            result = process_record(record)
            results.append(result)
            logger.info(
                "Processed s3://%s/%s -> HTTP %s",
                result["bucket"],
                result["key"],
                result["status_code"],
            )
        except (ValidationError, ConfigError) as exc:
            logger.error("Non-retryable error for key=%s: %s", key_for_log, exc)
            errors.append({"key": key_for_log, "error": str(exc)})
        except Exception as exc:
            logger.exception("Unexpected/retryable error for key=%s", key_for_log)
            errors.append({"key": key_for_log, "error": str(exc)})
            raise

    return {"processed": results, "errors": errors}
