# Loki log storage bucket — holds chunks + index (boltdb-shipper) for the
# logging stack. Private, encrypted at rest, versioning off (log data is
# write-once and already retention-managed via lifecycle rules below).
resource "aws_s3_bucket" "loki_logs" {
  bucket = "${var.project_name}-${var.environment}-loki-logs"
  tags = {
    Name        = "${var.project_name}-${var.environment}-loki-logs"
    Environment = var.environment
  }
}
resource "aws_s3_bucket_public_access_block" "loki_logs" {
  bucket                  = aws_s3_bucket.loki_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
# Retention: shorter in dev to keep storage cost near zero on a portfolio
# project; prod gets a longer window. Loki's own retention config (in the
# Helm values, set up in a later step) should match or stay under this.
resource "aws_s3_bucket_lifecycle_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.environment == "prod" ? 90 : 14
    }
  }
}

# Tempo trace storage bucket — holds trace blocks for the tracing stack.
# Private, encrypted at rest, versioning off (trace data is write-once,
# same rationale as Loki logs).
resource "aws_s3_bucket" "tempo_traces" {
  bucket = "${var.project_name}-${var.environment}-tempo-traces"
  tags = {
    Name        = "${var.project_name}-${var.environment}-tempo-traces"
    Environment = var.environment
  }
}
resource "aws_s3_bucket_public_access_block" "tempo_traces" {
  bucket                  = aws_s3_bucket.tempo_traces.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "tempo_traces" {
  bucket = aws_s3_bucket.tempo_traces.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
# Retention: same dev/prod split as Loki. Tempo's own block_retention
# (tempo.retention in Helm values, default 24h) should stay under this.
resource "aws_s3_bucket_lifecycle_configuration" "tempo_traces" {
  bucket = aws_s3_bucket.tempo_traces.id
  rule {
    id     = "expire-old-traces"
    status = "Enabled"
    filter {}
    expiration {
      days = var.environment == "prod" ? 90 : 14
    }
  }
}