variable "name_prefix" {
  description = "Prefix for role names."
  type        = string
}

variable "github_owner" {
  description = "GitHub owner used in the OIDC `sub` condition."
  type        = string
}

variable "github_repos" {
  description = "Repos that receive an OIDC role, one each."
  type        = list(string)
}

variable "raw_bucket" {
  description = "Raw bucket NAME (not ARN) — passed as a name to avoid a module cycle."
  type        = string
}

variable "serving_bucket" {
  description = "Serving bucket NAME (not ARN)."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name; its ARN is constructed here."
  type        = string
}

variable "ecs_family" {
  description = "ECS task definition family; used to scope the scheduler's RunTask."
  type        = string
}

variable "ecs_cluster" {
  description = "ECS cluster name; used to scope RunTask by cluster condition."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ingest ECR repository."
  type        = string
}

variable "secret_arns" {
  description = "Secrets Manager ARNs the ingest task and ECS agent may read."
  type        = list(string)
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider. Set false if the account already has one —
    it is an account-singleton and a second create fails with EntityAlreadyExists.
  EOT
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing provider ARN, used when create_github_oidc_provider is false."
  type        = string
  default     = ""
}
