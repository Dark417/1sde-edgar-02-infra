# ---------------------------------------------------------------------------
# The published interface (§7 / F-7).
#
# Adding a parameter here is adding to a public interface, so every one carries a
# comment naming its consumer. An unconsumed parameter is deleted.
#
# SSM rather than `terraform_remote_state` (rule 2): remote state would grant
# every consumer read access to every output in this state file, including role
# ARNs and anything else that ends up there. SSM gives per-parameter IAM, so
# repo 5 can be allowed to read the serving bucket name without also being able
# to enumerate the project's IAM roles.
# ---------------------------------------------------------------------------
locals {
  parameters = {
    # Consumed by: repo 1 (Liquibase JDBC target), repo 4 (job deploys), repo 5.
    "/edgar-lakehouse/dbx/host" = var.databricks_host

    # Consumed by: repo 3 (landing push target), repo 4 (Auto Loader source).
    "/edgar-lakehouse/dbx/volume_path" = var.volume_path

    # Consumed by: repo 1 (Liquibase), repo 5 (query endpoint).
    "/edgar-lakehouse/dbx/warehouse_id" = var.warehouse_id

    # Consumed by: repo 3 (S3 sink), repo 4 (Auto Loader source when mode = s3).
    "/edgar-lakehouse/s3/raw_bucket" = var.raw_bucket

    # Consumed by: repo 4 (Parquet export target), repo 5 (read path).
    "/edgar-lakehouse/s3/serving_bucket" = var.serving_bucket

    # Consumed by: repo 3 CI (image push target).
    "/edgar-lakehouse/ecr/ingest_repo" = var.ingest_repo_uri

    # Consumed by: repos 3, 4, 5 (pin the contracts wheel they install).
    "/edgar-lakehouse/contracts/version" = var.contracts_version

    # Consumed by: repo 3 (which sink is authoritative), repo 4 (which path Auto
    # Loader reads). ADR-001.
    "/edgar-lakehouse/landing_mode" = var.landing_mode

    # Consumed by: repo 3 CI (registers new task definition revisions).
    # NOTE: named as an SSM-published value in AGENTS.md §10 but absent from the
    # F-7 list. Flagged rather than silently dropped — see README.
    "/edgar-lakehouse/ecs/task_family" = var.ecs_family

    # NOTE: /edgar-lakehouse/dbx/job_id was removed 2026-08-02 along with the
    # job resource itself. Repo 4's bundle now creates and updates its own job,
    # so it has no need to look up an id this repo would have invented. Repo 4's
    # own ADR-006 had already flagged the parameter as having no consumer.
  }
}

resource "aws_ssm_parameter" "this" {
  for_each = local.parameters

  name  = each.key
  type  = "String"
  value = each.value

  # Values here are identifiers, not secrets. Anything sensitive belongs in
  # Secrets Manager and is referenced by ARN, never copied into a parameter.
  tier = "Standard"
}

# Consumed by: every repo's CI, to know which role to assume.
resource "aws_ssm_parameter" "oidc_role_arn" {
  for_each = var.oidc_role_arns

  name  = "/edgar-lakehouse/iam/oidc_role_arn/${each.key}"
  type  = "String"
  value = each.value
  tier  = "Standard"
}
