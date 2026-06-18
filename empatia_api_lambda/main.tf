###############################################################################
# main.tf - Empatia: API Gateway -> Lambda -> SQS -> S3 (landing)
#
# Flujo:
#   Cliente --POST--> WAF --> API Gateway (/detalle/events, /resumen/events)
#       --> Lambda (valida + enruta) --> SQS --> (consumidor aparte) --> S3
#
# Este archivo asume que ya tenes el WAF asociado al API Gateway (como
# mencionaste que ya lo creaste). Aca me enfoco en lo nuevo: API Gateway,
# Lambda, SQS y el bucket/paths de S3.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "stack_id" {
  description = "Identificador del stack, ej: augusta-nexa-dev"
  type        = string
}

variable "environment" {
  description = "Ambiente: dev, qa, prod"
  type        = string
  default     = "dev"
}

variable "landing_bucket_name" {
  description = "Nombre del bucket S3 de landing donde se guardan los JSON"
  type        = string
}

variable "api_stage_name" {
  description = "Nombre del stage del API Gateway, ej: dev-1"
  type        = string
  default     = "dev-1"
}

###############################################################################
# MODULO: SQS
# Una sola cola para ambos endpoints (detalle y resumen). El atributo
# "tipo_endpoint" en cada mensaje le dice al consumidor donde escribir.
###############################################################################
module "sqs" {
  source = "./modules/sqs"

  queue_name          = "${var.stack_id}-empatia-transcripciones"
  visibility_timeout  = 60
  message_retention_s = 86400 * 4 # 4 dias
  dlq_max_receive     = 5
}

###############################################################################
# MODULO: LAMBDA
# El handler que valida el JSON y lo manda a SQS.
###############################################################################
module "lambda_ingest" {
  source = "./modules/lambda"

  function_name = "${var.stack_id}-empatia-ingest"
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 10
  memory_size   = 256

  source_dir = "${path.module}/../lambda" # carpeta donde esta handler.py

  environment_variables = {
    SQS_QUEUE_URL = module.sqs.queue_url
  }

  sqs_queue_arn = module.sqs.queue_arn
}

###############################################################################
# MODULO: API GATEWAY
# Define los 2 endpoints (/empatia/detalle/events, /empatia/resumen/events)
# y los conecta al mismo Lambda.
###############################################################################
module "api_gateway" {
  source = "./modules/api_gateway"

  api_name        = "${var.stack_id}-empatia-api"
  stage_name      = var.api_stage_name
  lambda_invoke_arn = module.lambda_ingest.invoke_arn
  lambda_function_name = module.lambda_ingest.function_name

  # Define aca los recursos/paths. El modulo crea:
  #   /empatia/detalle/events
  #   /empatia/resumen/events
  base_path = "empatia"
  endpoints = ["detalle", "resumen"]
}

###############################################################################
# MODULO: S3 (landing) - paths en formato Hive
# resumen -> transacciones/empatia/transcripciones/resumen/anio=YYYY/mes=MM/dia=DD/
# detalle -> transacciones/empatia/transcripciones/detalle/anio=YYYY/mes=MM/dia=DD/
#
# NOTA: el bucket probablemente ya existe (dev-landing). Si es asi, usa
# `data "aws_s3_bucket"` en vez de crearlo. Lo dejo como recurso nuevo por
# claridad, pero te marco abajo la alternativa.
###############################################################################
module "s3_landing_paths" {
  source = "./modules/s3"

  bucket_name = var.landing_bucket_name

  # Estos son solo "carpetas" logicas (prefijos). S3 no tiene carpetas
  # reales, pero creamos objetos vacios para que el path quede visible
  # de una vez en la consola, y para fijar la convencion de nombres.
  prefixes = [
    "transacciones/empatia/transcripciones/detalle/",
    "transacciones/empatia/transcripciones/resumen/",
  ]
}

###############################################################################
# OUTPUTS
###############################################################################
output "invoke_url" {
  value = module.api_gateway.invoke_url
}

output "sqs_queue_url" {
  value = module.sqs.queue_url
}

output "lambda_function_name" {
  value = module.lambda_ingest.function_name
}
