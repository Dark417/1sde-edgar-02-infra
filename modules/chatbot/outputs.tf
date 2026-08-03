output "anthropic_api_key_secret_arn" {
  description = "ARN of the placeholder secret; repo 6's future task role reads exactly this."
  value       = aws_secretsmanager_secret.anthropic_api_key.arn
}
