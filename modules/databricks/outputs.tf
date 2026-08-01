output "catalog_name" {
  description = "Catalog name. Repo 1's Liquibase targets this."
  value       = databricks_catalog.this.name
}

output "schema_names" {
  description = "Created schema names keyed as passed in."
  value       = { for k, s in databricks_schema.this : k => s.name }
}

output "landing_volume_id" {
  description = "Fully qualified landing volume id."
  value       = databricks_volume.landing_edgar.id
}

output "wheel_volume_id" {
  description = "Fully qualified wheels volume id; repo 4's CI uploads here."
  value       = databricks_volume.wheels.id
}

output "job_id" {
  description = "Daily job id. Repo 4 updates its task wheel version."
  value       = databricks_job.daily.id
}
