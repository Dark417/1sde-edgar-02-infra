# Outputs exist for humans reading `terraform output` and for the §9.8 audit.
# They are NOT the cross-repo interface — repos 3-5 read SSM at runtime and must
# never use `terraform_remote_state` against this state file (rule 2). Remote
# state would grant every consumer read access to every output, including the
# ones that are only here for debugging.

output "raw_bucket" {
  description = "System-of-record landing bucket."
  value       = module.storage.raw_bucket_id
}

output "serving_bucket" {
  description = "Parquet export bucket, written by repo 4, read by repo 5."
  value       = module.storage.serving_bucket_id
}

output "ingest_repository_url" {
  description = "ECR repository repo 3 pushes to."
  value       = module.registry.repository_url
}

output "ecs_task_definition_family" {
  description = "Deploy target family for repo 3."
  value       = module.compute.family
}

output "oidc_role_arns" {
  description = "GitHub Actions OIDC role ARNs, one per repo."
  value       = module.iam.oidc_role_arns
}

output "ingest_task_role_arn" {
  description = "Role the ingest container runs as."
  value       = module.iam.ingest_task_role_arn
}

output "catalog_name" {
  description = "Unity Catalog catalog. Liquibase (repo 1) targets this."
  value       = module.databricks.catalog_name
}

output "volume_path" {
  description = "Managed landing volume path."
  value       = local.volume_landing
}

output "schedule_state" {
  description = "ENABLED/DISABLED. Must read DISABLED until repo 4 has run by hand."
  value       = module.schedule.state
}
