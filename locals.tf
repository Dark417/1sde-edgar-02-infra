# ---------------------------------------------------------------------------
# Block 1: literal mirrors of `edgar_lakehouse_contracts.names`.
#
# These MUST equal the package constants exactly. Every value here is a plain
# literal with no interpolation, because tests/test_names_match_contracts.py
# parses this block with python-hcl2 and compares it to the installed wheel.
# Introducing a `${...}` here would make the test compare a template string and
# silently pass. Derived values belong in block 2 below.
# ---------------------------------------------------------------------------
locals {
  catalog = "edgar"

  schema_landing = "landing"
  schema_bronze  = "bronze"
  schema_silver  = "silver"
  schema_gold    = "gold"

  raw_bucket     = "edgar-lake-raw"
  serving_bucket = "edgar-lake-serving"

  volume_landing = "/Volumes/edgar/landing/edgar"
}

# ---------------------------------------------------------------------------
# Block 2: derived values. Free to interpolate.
# ---------------------------------------------------------------------------
locals {
  name_prefix = "edgar-lakehouse"

  tags = {
    project    = "edgar-lakehouse"
    repo       = "1sde-databricks-edgar-02-infra"
    managed_by = "terraform"
    env        = var.env
  }

  # Ordered so the Databricks module can for_each without a perpetual diff.
  schemas = {
    landing = local.schema_landing
    bronze  = local.schema_bronze
    silver  = local.schema_silver
    gold    = local.schema_gold
  }

  # The name component of VOLUME_LANDING ("/Volumes/<catalog>/<schema>/<name>").
  # Derived rather than restated so the two cannot drift.
  volume_name = element(split("/", local.volume_landing), 4)

  # Deterministic AWS resource names. These are locals rather than module
  # outputs precisely so that IAM can construct the ARNs of resources it grants
  # access to without depending on the modules that create them (see main.tf).
  ecs_cluster    = "edgar-lakehouse-ingest"
  ecs_family     = "1sde-databricks-edgar-03-ingest"
  log_group_name = "/ecs/edgar-lakehouse-ingest"

  # Every repo that gets a GitHub Actions OIDC role. These must match the GitHub
  # repository names exactly — they are interpolated into the OIDC `sub`
  # condition, and a mismatch fails closed at CI auth time with an unhelpful
  # "not authorized to perform sts:AssumeRoleWithWebIdentity".
  github_repos = [
    "1sde-databricks-edgar-01-contracts",
    "1sde-databricks-edgar-02-infra",
    "1sde-databricks-edgar-03-ingest",
    "1sde-databricks-edgar-04-pipelines",
    "1sde-databricks-edgar-05-serving",
  ]
}
