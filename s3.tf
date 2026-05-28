# ── Upload the Glue Python script to the landing bucket ───────────────────────
# The bucket itself ("dev-landing") is pre-existing and managed elsewhere.
# We only manage the script object so the Glue job can find it at startup.
resource "aws_s3_object" "glue_script" {
  bucket = data.aws_s3_bucket.landing.bucket
  key    = local.script_s3_key
  source = "${path.module}/scripts/extractor.py"
  etag   = filemd5("${path.module}/scripts/extractor.py")

  tags = local.common_tags
}
