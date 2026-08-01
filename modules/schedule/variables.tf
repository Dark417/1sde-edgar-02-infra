variable "name_prefix" {
  description = "Prefix for the schedule name."
  type        = string
}

variable "schedule_enabled" {
  description = <<-EOT
    Rule 4. Defaults to false everywhere it appears. An enabled schedule pointing
    at unproven code burns the Free Edition daily quota and fills S3 with
    garbage; a human enables it only after repo 4 has run by hand (§9.9).
  EOT
  type        = bool
  default     = false
}

variable "cluster_arn" {
  description = "ECS cluster to run the task in."
  type        = string
}

variable "task_definition_arn" {
  description = "Task definition revision to run."
  type        = string
}

variable "scheduler_role_arn" {
  description = "Role EventBridge Scheduler assumes."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the task's ENI."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for the task's ENI."
  type        = list(string)
}

variable "schedule_expression" {
  description = "06:00 UTC daily."
  type        = string
  default     = "cron(0 6 * * ? *)"
}
