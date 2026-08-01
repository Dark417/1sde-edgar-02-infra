output "terraform_role_arn" {
  description = "Terraform execution role; the sole principal allowed to delete from the raw zone."
  value       = aws_iam_role.terraform.arn
}

output "ingest_task_role_arn" {
  description = "Application role for the ingest container."
  value       = aws_iam_role.ingest_task.arn
}

output "ingest_execution_role_arn" {
  description = "ECS agent role for the ingest task."
  value       = aws_iam_role.ingest_execution.arn
}

output "scheduler_role_arn" {
  description = "Role EventBridge Scheduler assumes to run the task."
  value       = aws_iam_role.scheduler.arn
}

output "oidc_role_arns" {
  description = "GitHub Actions OIDC role ARNs keyed by repository name."
  value       = { for repo, role in aws_iam_role.oidc : repo => role.arn }
}
