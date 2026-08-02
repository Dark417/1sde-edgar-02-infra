variable "databricks_host" {
  type = string
}

variable "volume_path" {
  type = string
}

variable "warehouse_id" {
  type = string
}

variable "raw_bucket" {
  type = string
}

variable "serving_bucket" {
  type = string
}

variable "ingest_repo_uri" {
  type = string
}

variable "contracts_version" {
  type = string
}

variable "landing_mode" {
  type = string
}

variable "oidc_role_arns" {
  description = "Repository name -> OIDC role ARN."
  type        = map(string)
}

variable "ecs_family" {
  type = string
}

