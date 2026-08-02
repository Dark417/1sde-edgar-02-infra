# Layer rule (AGENTS.md §4): this file contains ONLY module blocks and their
# wiring. A `resource` here is a review failure. Modules never call other
# modules — the root passes outputs between them.
#
# Module order below is also the dependency order. Two would-be cycles are
# broken by constructing ARNs from deterministic names rather than by taking a
# module output:
#   iam -> compute   (log group, task definition) : names are locals, so the
#                     ARNs are knowable before the resources exist.
#   iam -> storage   (bucket policy needs the TF role ARN) : resolved by making
#                     storage depend on iam, and iam depend only on bucket NAMES.

module "registry" {
  source = "./modules/registry"

  name_prefix = local.name_prefix
}

module "iam" {
  source = "./modules/iam"

  name_prefix  = local.name_prefix
  github_owner = var.github_owner
  github_repos = local.github_repos

  # Names, not module outputs — see the cycle note above. The serving bucket is
  # absent deliberately: repo 5's read access is granted by that bucket's policy
  # in modules/storage, so IAM has no use for it.
  raw_bucket     = local.raw_bucket
  log_group_name = local.log_group_name
  ecs_family     = local.ecs_family
  ecs_cluster    = local.ecs_cluster

  ecr_repository_arn = module.registry.repository_arn

  secret_arns = [
    data.aws_secretsmanager_secret.databricks_pat.arn,
    data.aws_secretsmanager_secret.sec_user_agent.arn,
  ]
}

module "storage" {
  source = "./modules/storage"

  raw_bucket         = local.raw_bucket
  serving_bucket     = local.serving_bucket
  ia_transition_days = var.ia_transition_days

  # The raw zone is the system of record; only this role may delete from it.
  terraform_role_arn = module.iam.terraform_role_arn

  # Repo 5 reads the Parquet export with credentials. The bucket stays private.
  serving_reader_role_arns = [
    module.iam.oidc_role_arns["1sde-edgar-05-serving"],
  ]
}

module "compute" {
  source = "./modules/compute"

  name_prefix        = local.name_prefix
  cluster_name       = local.ecs_cluster
  family             = local.ecs_family
  log_group_name     = local.log_group_name
  log_retention_days = var.log_retention_days

  repository_url = module.registry.repository_url
  image_tag      = var.ingest_image_tag
  image_digest   = var.ingest_image_digest

  task_role_arn      = module.iam.ingest_task_role_arn
  execution_role_arn = module.iam.ingest_execution_role_arn

  ingest_env = merge(var.ingest_env, {
    LANDING_MODE = var.landing_mode
    RAW_BUCKET   = local.raw_bucket
    AWS_REGION   = var.aws_region
  })

  secret_env = {
    SEC_USER_AGENT = data.aws_secretsmanager_secret.sec_user_agent.arn
  }
}

module "schedule" {
  source = "./modules/schedule"

  name_prefix         = local.name_prefix
  schedule_enabled    = var.schedule_enabled
  cluster_arn         = module.compute.cluster_arn
  task_definition_arn = module.compute.task_definition_arn
  scheduler_role_arn  = module.iam.scheduler_role_arn
  subnet_ids          = module.compute.subnet_ids
  security_group_ids  = [module.compute.security_group_id]
}

module "databricks" {
  source = "./modules/databricks"

  catalog             = local.catalog
  schemas             = local.schemas
  volume_schema       = local.schema_landing
  volume_name         = local.volume_name
  workspace_principal = var.workspace_principal

  # No job inputs. The job definition moved to repo 4's Asset Bundle — see the
  # note in modules/databricks/main.tf for why a Databricks job cannot be
  # declared from here the way an ECS task definition can.
}

module "params" {
  source = "./modules/params"

  databricks_host   = var.databricks_host
  volume_path       = local.volume_landing
  warehouse_id      = var.warehouse_id
  raw_bucket        = module.storage.raw_bucket_id
  serving_bucket    = module.storage.serving_bucket_id
  ingest_repo_uri   = module.registry.repository_url
  contracts_version = var.contracts_version
  landing_mode      = var.landing_mode
  oidc_role_arns    = module.iam.oidc_role_arns
  ecs_family        = module.compute.family
}
