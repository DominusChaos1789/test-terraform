"""
Unit tests for lambda_handler.py using pytest + unittest.mock.

Run from the local_test/ folder (with lambda_handler.py copied next to it):
    cp ../lambda_handler.py .
    pip install pytest boto3 --break-system-packages
    pytest test_lambda_handler.py -v

No real AWS calls are made — boto3 clients are fully mocked at import time.
AWS_DEFAULT_REGION is set before the module loads so boto3 never raises
a NoRegionError.
"""

import os
import json
import re
import pytest
from unittest.mock import patch, MagicMock

# -- Set required env vars BEFORE importing the handler ---------------------
os.environ["AWS_DEFAULT_REGION"] = "us-east-2"
os.environ["SQS_QUEUE_URL"] = "https://sqs.us-east-2.amazonaws.com/123456789/fake-queue"
os.environ["S3_BUCKET"] = "augusta-nexa-dev"

# -- Shared boto3 mocks (applied for the whole module) ----------------------
mock_sqs = MagicMock()
mock_s3 = MagicMock()
mock_sqs.send_message.return_value = {"MessageId": "mock-sqs-id-001"}
mock_s3.put_object.return_value = {}


def fake_boto3_client(service, *args, **kwargs):
    if service == "sqs":
        return mock_sqs
    if service == "s3":
        return mock_s3
    return MagicMock()


# Patch boto3.client BEFORE the module-level sqs/s3 = boto3.client() lines run
with patch("boto3.client", side_effect=fake_boto3_client):
    import lambda_handler


# ===========================================================================
# HELPERS
# ===========================================================================

def _make_event(resource: str, body: dict) -> dict:
    """Builds a minimal API Gateway proxy event."""
    return {
        "resource": resource,
        "httpMethod": "POST",
        "headers": {
            "Content-Type": "application/json",
            "Authorization": "Bearer mock-cognito-token",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _body(response: dict) -> dict:
    """Parses the JSON body string from a Lambda response dict."""
    return json.loads(response["body"])


# -- Valid payloads ----------------------------------------------------------

VALID_DETAILS_NATURAL = {
    "tenant_id": "empatia",
    "idLlamada": "call_0001",
    "tipoPersona": "Natural",
    "tipoIdentificacion": "CC",
    "numeroIdentificacion": "1234567890",
    "primerNombre": "Juan",
    "primerApellido": "Perez",
    "codigoTipificacion": "TIP001",
    "descripcionTipificacion": "Consulta general",
    "fechaInicio": "2026-06-21T10:00:00Z",
    "data": {"conversacion": "Cliente: Hola.\nAgente: Hola, en que te ayudo?"},
}

VALID_DETAILS_JURIDICA = {
    "tenant_id": "empatia",
    "idLlamada": "call_0002",
    "tipoPersona": "Juridica",
    "tipoIdentificacion": "NIT",
    "numeroIdentificacion": "900123456",
    "razonSocial": "Acme SAS",
    "codigoTipificacion": "TIP001",
    "data": {"conversacion": "Llamada de empresa."},
}

VALID_SUMMARY_NATURAL = {
    "tenant_id": "empatia",
    "idLlamada": "call_0001",
    "tipoPersona": "Natural",
    "tipoIdentificacion": "CC",
    "numeroIdentificacion": "1234567890",
    "primerNombre": "Juan",
    "primerApellido": "Perez",
    "codigoTipificacion": "TIP002",
    "data": {"motivo": "Consulta de factura", "resumen": "Resuelto."},
}

VALID_SUMMARY_JURIDICA = {
    "tenant_id": "empatia",
    "idLlamada": "call_0002",
    "tipoPersona": "Juridica",
    "tipoIdentificacion": "NIT",
    "numeroIdentificacion": "900123456",
    "razonSocial": "Acme SAS",
    "codigoTipificacion": "TIP002",
    "data": {"motivo": "Soporte tecnico", "resumen": "Incidencia cerrada."},
}


# ===========================================================================
# 1 — HAPPY PATH  (/details)
# ===========================================================================

class TestDetailsHappyPath:

    def test_valid_natural_returns_202(self):
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 202

    def test_valid_natural_response_has_record_id(self):
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        body = _body(lambda_handler.lambda_handler(event, {}))
        assert "record_id" in body
        assert len(body["record_id"]) == 36  # UUID4

    def test_valid_natural_endpoint_field_is_details(self):
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        assert _body(lambda_handler.lambda_handler(event, {}))["endpoint"] == "details"

    def test_valid_natural_s3_key_uses_detalle_prefix(self):
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        s3_key = _body(lambda_handler.lambda_handler(event, {}))["s3_key"]
        assert "empatia/transcripciones/detalle/api/" in s3_key

    def test_valid_natural_s3_key_has_hive_partitions(self):
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        s3_key = _body(lambda_handler.lambda_handler(event, {}))["s3_key"]
        assert re.search(r"year=\d{4}/month=\d{2}/day=\d{2}/", s3_key)

    def test_valid_juridica_returns_202(self):
        event = _make_event("/empatia/details/events", VALID_DETAILS_JURIDICA)
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 202

    def test_sqs_send_message_is_called(self):
        mock_sqs.reset_mock()
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        lambda_handler.lambda_handler(event, {})
        mock_sqs.send_message.assert_called_once()

    def test_s3_put_object_is_called(self):
        mock_s3.reset_mock()
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        lambda_handler.lambda_handler(event, {})
        mock_s3.put_object.assert_called_once()

    def test_s3_put_object_bucket_is_correct(self):
        mock_s3.reset_mock()
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        lambda_handler.lambda_handler(event, {})
        assert mock_s3.put_object.call_args.kwargs["Bucket"] == "augusta-nexa-dev"


# ===========================================================================
# 2 — HAPPY PATH  (/summary)
# ===========================================================================

class TestSummaryHappyPath:

    def test_valid_natural_returns_202(self):
        event = _make_event("/empatia/summary/events", VALID_SUMMARY_NATURAL)
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 202

    def test_valid_natural_endpoint_field_is_summary(self):
        event = _make_event("/empatia/summary/events", VALID_SUMMARY_NATURAL)
        assert _body(lambda_handler.lambda_handler(event, {}))["endpoint"] == "summary"

    def test_valid_natural_s3_key_uses_resumen_prefix(self):
        event = _make_event("/empatia/summary/events", VALID_SUMMARY_NATURAL)
        s3_key = _body(lambda_handler.lambda_handler(event, {}))["s3_key"]
        assert "empatia/transcripciones/resumen/api/" in s3_key

    def test_valid_juridica_returns_202(self):
        event = _make_event("/empatia/summary/events", VALID_SUMMARY_JURIDICA)
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 202


# ===========================================================================
# 3 — _validate_common_fields (unit tests for the helper directly)
# ===========================================================================

class TestValidateCommonFields:

    def test_returns_none_for_valid_payload(self):
        assert lambda_handler._validate_common_fields(VALID_DETAILS_NATURAL) is None

    @pytest.mark.parametrize("field", [
        "tenant_id",
        "tipoPersona",
        "tipoIdentificacion",
        "numeroIdentificacion",
        "codigoTipificacion",
        "data",
    ])
    def test_missing_required_field_returns_error(self, field):
        payload = {**VALID_DETAILS_NATURAL}
        del payload[field]
        result = lambda_handler._validate_common_fields(payload)
        assert result is not None
        assert field in result

    def test_invalid_tipo_persona_returns_error(self):
        payload = {**VALID_DETAILS_NATURAL, "tipoPersona": "Empresa"}
        result = lambda_handler._validate_common_fields(payload)
        assert result is not None
        assert "tipoPersona" in result

    @pytest.mark.parametrize("valid_value", ["Natural", "Juridica"])
    def test_valid_tipo_persona_values_pass(self, valid_value):
        payload = {**VALID_DETAILS_NATURAL, "tipoPersona": valid_value}
        # only testing common fields, so inject the conditional fields too
        payload.setdefault("primerNombre", "x")
        payload.setdefault("primerApellido", "x")
        assert lambda_handler._validate_common_fields(payload) is None


# ===========================================================================
# 4 — _validate_identity_fields (unit tests for the helper directly)
# ===========================================================================

class TestValidateIdentityFields:

    def test_natural_with_both_name_fields_returns_none(self):
        assert lambda_handler._validate_identity_fields(VALID_DETAILS_NATURAL) is None

    def test_juridica_with_razon_social_returns_none(self):
        assert lambda_handler._validate_identity_fields(VALID_DETAILS_JURIDICA) is None

    def test_natural_missing_primer_nombre_returns_error(self):
        payload = {**VALID_DETAILS_NATURAL}
        del payload["primerNombre"]
        result = lambda_handler._validate_identity_fields(payload)
        assert result is not None
        assert "primerNombre" in result

    def test_natural_missing_primer_apellido_returns_error(self):
        payload = {**VALID_DETAILS_NATURAL}
        del payload["primerApellido"]
        result = lambda_handler._validate_identity_fields(payload)
        assert result is not None
        assert "primerApellido" in result

    def test_natural_missing_both_name_fields_error_mentions_both(self):
        payload = {**VALID_DETAILS_NATURAL}
        del payload["primerNombre"]
        del payload["primerApellido"]
        result = lambda_handler._validate_identity_fields(payload)
        assert "primerNombre" in result
        assert "primerApellido" in result

    def test_juridica_missing_razon_social_returns_error(self):
        payload = {**VALID_DETAILS_JURIDICA}
        del payload["razonSocial"]
        result = lambda_handler._validate_identity_fields(payload)
        assert result is not None
        assert "razonSocial" in result

    def test_natural_does_not_need_razon_social(self):
        payload = {**VALID_DETAILS_NATURAL}
        payload.pop("razonSocial", None)
        assert lambda_handler._validate_identity_fields(payload) is None

    def test_juridica_does_not_need_primer_nombre_apellido(self):
        payload = {**VALID_DETAILS_JURIDICA}
        payload.pop("primerNombre", None)
        payload.pop("primerApellido", None)
        assert lambda_handler._validate_identity_fields(payload) is None


# ===========================================================================
# 5 — _validate_data_object (unit tests for the helper directly)
# ===========================================================================

class TestValidateDataObject:

    def test_details_valid_data_returns_none(self):
        assert lambda_handler._validate_data_object("details", VALID_DETAILS_NATURAL) is None

    def test_summary_valid_data_returns_none(self):
        assert lambda_handler._validate_data_object("summary", VALID_SUMMARY_NATURAL) is None

    def test_details_missing_conversacion_returns_error(self):
        payload = {**VALID_DETAILS_NATURAL, "data": {}}
        result = lambda_handler._validate_data_object("details", payload)
        assert result is not None
        assert "conversacion" in result

    def test_summary_missing_motivo_returns_error(self):
        payload = {**VALID_SUMMARY_NATURAL, "data": {"resumen": "x"}}
        result = lambda_handler._validate_data_object("summary", payload)
        assert result is not None
        assert "motivo" in result

    def test_summary_missing_resumen_returns_error(self):
        payload = {**VALID_SUMMARY_NATURAL, "data": {"motivo": "x"}}
        result = lambda_handler._validate_data_object("summary", payload)
        assert result is not None
        assert "resumen" in result

    def test_summary_missing_both_data_fields_mentions_them(self):
        payload = {**VALID_SUMMARY_NATURAL, "data": {}}
        result = lambda_handler._validate_data_object("summary", payload)
        assert "motivo" in result or "resumen" in result

    def test_data_not_a_dict_returns_error(self):
        payload = {**VALID_DETAILS_NATURAL, "data": "not a dict"}
        result = lambda_handler._validate_data_object("details", payload)
        assert result is not None
        assert "JSON object" in result


# ===========================================================================
# 6 — HTTP / routing errors
# ===========================================================================

class TestRoutingErrors:

    def test_invalid_json_body_returns_400(self):
        event = {
            "resource": "/empatia/details/events",
            "httpMethod": "POST",
            "headers": {"Content-Type": "application/json"},
            "body": '{"tenant_id": "empatia",}',  # trailing comma
        }
        resp = lambda_handler.lambda_handler(event, {})
        assert resp["statusCode"] == 400
        assert "Invalid JSON" in _body(resp)["error"]

    def test_wrong_http_method_returns_405(self):
        event = {
            "resource": "/empatia/details/events",
            "httpMethod": "GET",
            "headers": {},
            "body": None,
        }
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 405

    def test_unknown_endpoint_returns_404(self):
        event = _make_event("/empatia/unknown/events", VALID_DETAILS_NATURAL)
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 404

    def test_empty_body_returns_400(self):
        event = {
            "resource": "/empatia/details/events",
            "httpMethod": "POST",
            "headers": {"Content-Type": "application/json"},
            "body": "",
        }
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 400

    def test_none_body_returns_400(self):
        event = {
            "resource": "/empatia/details/events",
            "httpMethod": "POST",
            "headers": {"Content-Type": "application/json"},
            "body": None,
        }
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 400


# ===========================================================================
# 7 — SQS / S3 failure handling
# ===========================================================================

class TestAWSFailures:

    def test_sqs_failure_returns_500(self):
        mock_sqs.send_message.side_effect = Exception("SQS unavailable")
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        resp = lambda_handler.lambda_handler(event, {})
        assert resp["statusCode"] == 500
        mock_sqs.send_message.side_effect = None
        mock_sqs.send_message.return_value = {"MessageId": "mock-sqs-id-001"}

    def test_sqs_failure_error_message(self):
        mock_sqs.send_message.side_effect = Exception("SQS unavailable")
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        assert "Failed to queue" in _body(lambda_handler.lambda_handler(event, {}))["error"]
        mock_sqs.send_message.side_effect = None
        mock_sqs.send_message.return_value = {"MessageId": "mock-sqs-id-001"}

    def test_s3_failure_does_not_return_500(self):
        """S3 write failure is non-fatal — request should still return 202."""
        mock_s3.put_object.side_effect = Exception("S3 unavailable")
        event = _make_event("/empatia/details/events", VALID_DETAILS_NATURAL)
        assert lambda_handler.lambda_handler(event, {})["statusCode"] == 202
        mock_s3.put_object.side_effect = None
        mock_s3.put_object.return_value = {}
