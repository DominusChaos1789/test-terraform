###############################################################################
# modules/s3/main.tf
#
# Si el bucket "landing" YA EXISTE (lo mas probable, dado tu setup actual),
# reemplaza el aws_s3_bucket de abajo por un data source:
#
#   data "aws_s3_bucket" "landing" {
#     bucket = var.bucket_name
#   }
#
# y cambia las referencias de aws_s3_bucket.landing.id por
# data.aws_s3_bucket.landing.id
###############################################################################

variable "bucket_name" {
  type = string
}

variable "prefixes" {
  description = "Prefijos/carpetas logicas a inicializar"
  type        = list(string)
  default     = []
}

resource "aws_s3_bucket" "landing" {
  bucket = var.bucket_name
}

# Crea un objeto vacio por cada prefijo para que la "carpeta" aparezca
# de inmediato en la consola de S3. Es opcional: el consumidor real
# (Glue/Lambda que escribe los Parquet/JSON) va a crear estos paths
# de todas formas en cuanto llegue el primer mensaje.
resource "aws_s3_object" "folder_markers" {
  for_each = toset(var.prefixes)
  bucket   = aws_s3_bucket.landing.id
  key      = each.value
  content  = ""
}

output "bucket_name" {
  value = aws_s3_bucket.landing.id
}

output "prefixes" {
  value = var.prefixes
}
