variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name. Deterministic — IAM constructs its ARN."
  type        = string
}

variable "family" {
  description = "Task definition family. Deterministic — IAM and the scheduler construct its ARN."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name."
  type        = string
}

variable "log_retention_days" {
  description = "Explicit retention. The default of \"never expire\" is a slow bill (rule 9)."
  type        = number
  default     = 14
}

variable "repository_url" {
  description = "ECR repository URI."
  type        = string
}

variable "image_tag" {
  description = "Fallback tag, used only while the digest is unknown (first apply)."
  type        = string
  default     = "bootstrap"
}

variable "image_digest" {
  description = "Immutable digest supplied by repo 3's CI. Preferred over the tag."
  type        = string
  default     = ""
}

variable "task_role_arn" {
  description = "Application role the container runs as."
  type        = string
}

variable "execution_role_arn" {
  description = "ECS agent role that pulls the image and injects secrets."
  type        = string
}

variable "ingest_env" {
  description = "Non-secret environment variables."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = <<-EOT
    Secret environment variables as name -> Secrets Manager ARN. These are
    injected by ECS via `valueFrom`; the values never appear in the task
    definition, in Terraform state, or in a `terraform plan` diff.
  EOT
  type        = map(string)
  default     = {}
}

variable "cpu" {
  description = "Fargate CPU units. 512 = 0.5 vCPU."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Fargate memory in MiB."
  type        = number
  default     = 1024
}
