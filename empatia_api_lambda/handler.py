"""
Lambda handler - Empatia API Gateway -> SQS
=============================================

QUE HACE ESTE LAMBDA:
----------------------
1. Recibe el evento de API Gateway (HTTP POST con JSON en el body).
2. Identifica si la peticion vino del endpoint "/detalle/events" o
   "/resumen/events" usando el "resource path" que manda API Gateway.
3. Valida que el JSON tenga los campos obligatorios segun el tipo
   (detalle o resumen).
4. Si todo esta bien, envia el JSON a una cola SQS (la misma cola para
   ambos endpoints), agregando un atributo "tipo" para que el
   consumidor (otro Lambda/Glue job) sepa donde guardarlo en S3.
5. Responde al cliente con 200 si todo OK, o 400 si el JSON esta mal
   formado o le faltan campos.

IMPORTANTE - Lo que este Lambda NO hace:
------------------------------------------
- No escribe directamente a S3. Eso lo hace otro proceso (otro Lambda
  o un Glue Job) que LEE de la cola SQS y escribe el Parquet/JSON en
  el bucket "landing" particionado en formato Hive
  (tenant_id=x/anio=2026/mes=06/dia=18/...).
  Esto es justamente la migracion que ya tenias en mente:
  API Gateway -> Lambda -> SQS -> (consumidor) -> S3
  en vez de API Gateway -> SQS directo.

VARIABLES DE ENTORNO QUE NECESITA (configuralas en Terraform/Lambda):
------------------------------------------------------------------------
- SQS_QUEUE_URL : URL completa de la cola SQS destino.
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3

# ---------------------------------------------------------------------
# Configuracion / clientes (se inicializan UNA vez, fuera del handler,
# para que Lambda los reutilice entre invocaciones - mejora performance)
# ---------------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs_client = boto3.client("sqs")
QUEUE_URL = os.environ["SQS_QUEUE_URL"]

# ---------------------------------------------------------------------
# Definimos los campos obligatorios para cada tipo de documento.
# Si en el futuro agregan un endpoint nuevo, solo hay que agregar
# una entrada aca.
# ---------------------------------------------------------------------
CAMPOS_COMUNES = [
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

CAMPOS_POR_TIPO = {
    "detalle": {
        "tipo_esperado": "conversacion",
        "campos_data": ["conversacion"],
    },
    "resumen": {
        "tipo_esperado": "resumen",
        "campos_data": ["motivo", "resumen"],
    },
}


def _respuesta(status_code: int, body: dict) -> dict:
    """
    Armar la respuesta en el formato que API Gateway espera
    cuando se usa integracion Lambda Proxy.
    """
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _identificar_tipo_endpoint(event: dict) -> str:
    """
    Detecta si la peticion vino de /detalle o /resumen mirando el
    'resource' o el 'path' que manda API Gateway.

    Ejemplo de event["resource"]: "/empatia/detalle/events"
    Ejemplo de event["path"]:     "/dev-1/empatia/detalle/events"
    """
    resource = event.get("resource", "") or event.get("path", "")
    resource = resource.lower()

    if "detalle" in resource:
        return "detalle"
    if "resumen" in resource:
        return "resumen"
    return ""


def _validar_payload(payload: dict, tipo_endpoint: str) -> list:
    """
    Valida que el JSON tenga los campos obligatorios.
    Devuelve una LISTA de errores. Si la lista esta vacia, el JSON
    esta valido.
    """
    errores = []

    # 1. Validar campos de primer nivel (comunes a detalle y resumen)
    for campo in CAMPOS_COMUNES:
        if campo not in payload:
            errores.append(f"Falta el campo obligatorio: '{campo}'")

    # Si ya falta algo basico, no seguimos validando "data" para
    # evitar errores en cascada confusos.
    if errores:
        return errores

    # 2. Validar que el campo "tipo" coincida con el endpoint usado.
    #    Ej: si pegaron al endpoint /resumen pero mandaron "tipo": "conversacion"
    config = CAMPOS_POR_TIPO.get(tipo_endpoint)
    tipo_esperado = config["tipo_esperado"]
    if payload.get("tipo") != tipo_esperado:
        errores.append(
            f"El campo 'tipo' debe ser '{tipo_esperado}' para el endpoint "
            f"'{tipo_endpoint}', se recibio: '{payload.get('tipo')}'"
        )

    # 3. Validar que "data" sea un diccionario y tenga los campos
    #    especificos de ese tipo de documento.
    data = payload.get("data")
    if not isinstance(data, dict):
        errores.append("El campo 'data' debe ser un objeto JSON")
    else:
        for campo_data in config["campos_data"]:
            if campo_data not in data:
                errores.append(
                    f"Falta el campo obligatorio dentro de 'data': '{campo_data}'"
                )

    return errores


def lambda_handler(event, context):
    """
    Punto de entrada de Lambda. API Gateway llama esta funcion en
    cada POST que llega a /detalle/events o /resumen/events.
    """
    logger.info("Evento recibido: %s", json.dumps(event)[:500])

    # -------------------------------------------------------------
    # PASO 1: Identificar a que endpoint le pegaron
    # -------------------------------------------------------------
    tipo_endpoint = _identificar_tipo_endpoint(event)

    if tipo_endpoint not in CAMPOS_POR_TIPO:
        return _respuesta(
            400,
            {
                "mensaje": "No se pudo identificar el endpoint (detalle/resumen).",
                "resource_recibido": event.get("resource"),
            },
        )

    # -------------------------------------------------------------
    # PASO 2: Parsear el body. El body llega como STRING dentro del
    # event, hay que convertirlo a diccionario de Python.
    # -------------------------------------------------------------
    raw_body = event.get("body")

    if raw_body is None:
        return _respuesta(400, {"mensaje": "El body de la peticion esta vacio."})

    try:
        payload = json.loads(raw_body)
    except (json.JSONDecodeError, TypeError) as exc:
        logger.warning("JSON invalido recibido: %s", exc)
        return _respuesta(
            400,
            {"mensaje": "El body no es un JSON valido.", "detalle_error": str(exc)},
        )

    if not isinstance(payload, dict):
        return _respuesta(400, {"mensaje": "El JSON debe ser un objeto, no una lista u otro tipo."})

    # -------------------------------------------------------------
    # PASO 3: Validar los campos obligatorios
    # -------------------------------------------------------------
    errores = _validar_payload(payload, tipo_endpoint)
    if errores:
        return _respuesta(
            400,
            {
                "mensaje": "El JSON no cumple con el formato esperado.",
                "errores": errores,
            },
        )

    # -------------------------------------------------------------
    # PASO 4: Enriquecer el mensaje con metadata util para el
    # consumidor (quien va a leer de SQS y escribir a S3).
    # Esto es lo que le permite al consumidor saber:
    #   - en que carpeta de S3 guardar (tipo_endpoint)
    #   - cuando llego realmente a la API (no la fecha que manda el cliente)
    #   - un id unico de mensaje para trazabilidad/logs
    # -------------------------------------------------------------
    mensaje_sqs = {
        "tipo_endpoint": tipo_endpoint,  # "detalle" o "resumen" -> define carpeta en S3
        "recibido_en": datetime.now(timezone.utc).isoformat(),
        "request_id": context.aws_request_id if context else str(uuid.uuid4()),
        "payload": payload,
    }

    # -------------------------------------------------------------
    # PASO 5: Enviar a SQS
    # -------------------------------------------------------------
    try:
        sqs_client.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(mensaje_sqs, ensure_ascii=False),
            MessageAttributes={
                "tipo_endpoint": {
                    "DataType": "String",
                    "StringValue": tipo_endpoint,
                },
                "tenant_id": {
                    "DataType": "String",
                    "StringValue": str(payload.get("tenant_id", "desconocido")),
                },
            },
        )
    except Exception as exc:
        logger.error("Error enviando mensaje a SQS: %s", exc)
        return _respuesta(
            502,
            {"mensaje": "No se pudo encolar el mensaje. Intente nuevamente.", "detalle_error": str(exc)},
        )

    logger.info(
        "Mensaje encolado correctamente. tipo=%s tenant_id=%s conversacion_id=%s",
        tipo_endpoint,
        payload.get("tenant_id"),
        payload.get("conversacion_id"),
    )

    # -------------------------------------------------------------
    # PASO 6: Responder al cliente
    # -------------------------------------------------------------
    return _respuesta(
        200,
        {
            "mensaje": "Documento recibido correctamente.",
            "tipo": tipo_endpoint,
            "conversacion_id": payload.get("conversacion_id"),
        },
    )
