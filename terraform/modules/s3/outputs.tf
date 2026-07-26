output "loki_logs_bucket_name" {
  value = aws_s3_bucket.loki_logs.bucket
}

output "loki_logs_bucket_arn" {
  value = aws_s3_bucket.loki_logs.arn
}