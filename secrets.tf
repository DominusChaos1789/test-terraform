###############################################################################
# secrets.tf
#
# Secrets Manager – one secret per schema storing DB credentials.
###############################################################################

resource "aws_secretsmanager_secret" "schema_credentials" {
  for_each = local.schema_map

  name                    = "${var.environment}/${var.project}/${each.key}/db-credentials"
  description             = "Aurora MySQL credentials for schema ${each.key}"
  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(var.tags, { Schema = each.key })
}

resource "aws_secretsmanager_secret_version" "schema_credentials" {
  for_each = local.schema_map

  secret_id = aws_secretsmanager_secret.schema_credentials[each.key].id
  secret_string = jsonencode({
    username = each.value.db_user
    password = each.value.db_password
    host     = each.value.db_host
    port     = each.value.db_port
    dbname   = each.value.db_name
  })
}
