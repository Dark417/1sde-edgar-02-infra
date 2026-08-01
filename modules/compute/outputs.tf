output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "task_definition_arn" {
  description = "Current task definition revision ARN."
  value       = aws_ecs_task_definition.ingest.arn
}

output "family" {
  description = "Task definition family; repo 3 registers new revisions against it."
  value       = aws_ecs_task_definition.ingest.family
}

output "security_group_id" {
  description = "Egress-only security group for the task."
  value       = aws_security_group.task.id
}

output "subnet_ids" {
  description = "Subnets the task runs in."
  value       = data.aws_subnets.default.ids
}

output "log_group_name" {
  description = "CloudWatch log group receiving container output."
  value       = aws_cloudwatch_log_group.ingest.name
}
