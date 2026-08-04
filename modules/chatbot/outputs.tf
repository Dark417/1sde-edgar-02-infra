output "anthropic_api_key_secret_arn" {
  description = "ARN of the placeholder secret; repo 6's future task role reads exactly this."
  value       = aws_secretsmanager_secret.anthropic_api_key.arn
}

output "chatbot_url" {
  description = "Where the demo is reachable. Null until deploy_chatbot = true."
  value = (
    var.deploy_chatbot
    ? (var.chatbot_domain != "" ? "https://${var.chatbot_domain}" : "http://${aws_eip.chatbot[0].public_ip}:8501")
    : null
  )
}

output "chatbot_instance_id" {
  value = var.deploy_chatbot ? aws_instance.chatbot[0].id : null
}
