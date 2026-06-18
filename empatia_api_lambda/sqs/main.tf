###############################################################################
# modules/sqs/main.tf
# Crea la cola principal + una Dead Letter Queue (DLQ) para mensajes
# que fallen repetidamente al ser procesados por el consumidor.
###############################################################################

variable "queue_name" {
  type = string
}

variable "visibility_timeout" {
  type    = number
  default = 60
}

variable "message_retention_s" {
  type    = number
  default = 345600 # 4 dias
}

variable "dlq_max_receive" {
  description = "Cuantos intentos fallidos antes de mandar el mensaje a la DLQ"
  type        = number
  default     = 5
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.queue_name}-dlq"
  message_retention_seconds = 1209600 # 14 dias, para poder investigar fallos
}

resource "aws_sqs_queue" "main" {
  name                       = var.queue_name
  visibility_timeout_seconds = var.visibility_timeout
  message_retention_seconds  = var.message_retention_s

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount      = var.dlq_max_receive
  })
}

output "queue_url" {
  value = aws_sqs_queue.main.url
}

output "queue_arn" {
  value = aws_sqs_queue.main.arn
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}
