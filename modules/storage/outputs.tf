output "raw_bucket_id" {
  description = "Raw bucket name."
  value       = aws_s3_bucket.raw.id
}

output "raw_bucket_arn" {
  description = "Raw bucket ARN."
  value       = aws_s3_bucket.raw.arn
}

output "serving_bucket_id" {
  description = "Serving bucket name."
  value       = aws_s3_bucket.serving.id
}

output "serving_bucket_arn" {
  description = "Serving bucket ARN."
  value       = aws_s3_bucket.serving.arn
}
