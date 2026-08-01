output "repository_url" {
  description = "Registry URI repo 3 pushes to."
  value       = aws_ecr_repository.ingest.repository_url
}

output "repository_arn" {
  description = "ARN, used to scope the execution role's pull permissions."
  value       = aws_ecr_repository.ingest.arn
}

output "repository_name" {
  description = "Bare repository name."
  value       = aws_ecr_repository.ingest.name
}
