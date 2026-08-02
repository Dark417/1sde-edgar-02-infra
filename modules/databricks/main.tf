# ---------------------------------------------------------------------------
# Unity Catalog objects.
#
# Terraform owns the CONTAINERS: catalog, schemas, volumes. It does not own
# tables — Liquibase in repo 1 creates those (§1). Two tools owning the same
# object is how you get a destroy that silently drops a table Liquibase still
# thinks it manages. There is deliberately no table resource anywhere here.
#
# Everything in this file is workspace-scoped. Free Edition exposes no
# account-level API, so account-scoped resources would fail at runtime rather
# than at plan time (rule 1).
# ---------------------------------------------------------------------------
resource "databricks_catalog" "this" {
  name    = var.catalog
  comment = "SEC EDGAR medallion lakehouse. Tables are managed by Liquibase in repo 1."

  # Managed storage: Free Edition's default metastore root. No storage_root and
  # no external location are declared, because both are account-scoped concepts.

  # force_destroy stays at its default of false. A `terraform destroy` that took
  # the catalog with it would delete every table Liquibase created.

  lifecycle {
    ignore_changes = [
      # THIS BLOCK PREVENTS DATA LOSS. The catalog was created by hand before
      # this Terraform existed, so the metastore assigned it a storage_root.
      # Declaring nothing here reads as "remove storage_root", and that attribute
      # forces replacement — the first plan came back with "1 to destroy" and
      # "Warning: this will destroy the imported resource", which would have
      # dropped the catalog and all 13 Liquibase-managed tables inside it.
      #
      # storage_root is assigned by the metastore and is not this repo's to
      # manage. It is also environment-specific, so pinning the literal value in
      # config would be both wrong and a leak of internal storage paths.
      storage_root,

      # Set by Databricks at creation (collation and similar). Not ours either.
      properties,

      # Ownership is managed in the workspace, not here. Left unmanaged so a
      # plan does not churn every time it differs.
      owner,
    ]
  }
}

resource "databricks_schema" "this" {
  for_each = var.schemas

  catalog_name = databricks_catalog.this.name
  name         = each.value
  comment      = "Medallion layer: ${each.value}."
}

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------
resource "databricks_volume" "landing_edgar" {
  name         = var.volume_name
  catalog_name = databricks_catalog.this.name
  schema_name  = databricks_schema.this[var.volume_schema].name
  volume_type  = "MANAGED"
  comment      = "Landing zone transport. S3 remains the system of record (ADR-001)."
}

# NOTE: not named in AGENTS.md §6 F-6. Added because repo 4's job tasks install a
# private wheel that is not on PyPI, so it must be readable from a volume path.
# Without this the job graph below has nowhere to install from. Flagged for
# review rather than silently folded into the landing volume, which holds
# externally-landed data and should not also hold build artefacts.
resource "databricks_volume" "wheels" {
  name         = "wheels"
  catalog_name = databricks_catalog.this.name
  schema_name  = databricks_schema.this[var.volume_schema].name
  volume_type  = "MANAGED"
  comment      = "Build artefacts: the repo-4 pipelines wheel, uploaded by its CI."
}

# ---------------------------------------------------------------------------
# Grants
# ---------------------------------------------------------------------------
resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.this.name

  grant {
    principal  = var.workspace_principal
    privileges = ["USE_CATALOG", "USE_SCHEMA", "CREATE_TABLE", "MODIFY", "SELECT"]
  }
}

# Volume privileges are separate from catalog privileges in Unity Catalog and are
# not implied by the grant above. Repo 3 cannot push a landing object without
# WRITE_VOLUME, and Auto Loader cannot read one without READ_VOLUME.
resource "databricks_grants" "landing_volume" {
  volume = databricks_volume.landing_edgar.id

  grant {
    principal  = var.workspace_principal
    privileges = ["READ_VOLUME", "WRITE_VOLUME"]
  }
}

resource "databricks_grants" "wheels_volume" {
  volume = databricks_volume.wheels.id

  grant {
    principal  = var.workspace_principal
    privileges = ["READ_VOLUME", "WRITE_VOLUME"]
  }
}

# ---------------------------------------------------------------------------
# Daily medallion job
#
#   bronze_all ──► silver_filing ──┬──► silver_company ──┐
#                                  └──► silver_fact ─────┴──► gold_all ──► export_serving
#
# Peak concurrency is 2 (silver_company alongside silver_fact), well inside the
# Free Edition cap of 5 concurrent tasks.
#
# The bronze_all ──► gold_all edge drawn in AGENTS.md §6 F-6 is omitted: it is
# transitively implied by the path through silver, and a redundant edge in a task
# graph is noise that hides the real dependency structure.
# ---------------------------------------------------------------------------
locals {
  wheel = "${var.wheel_dir}/edgar_lakehouse_pipelines-${var.wheel_version}-py3-none-any.whl"

  package_name = "edgar_lakehouse_pipelines"

  # task_key -> list of task_keys it depends on.
  tasks = {
    bronze_all     = []
    silver_filing  = ["bronze_all"]
    silver_company = ["silver_filing"]
    silver_fact    = ["silver_filing"]
    gold_all       = ["silver_company", "silver_fact"]
    export_serving = ["gold_all"]
  }
}

resource "databricks_job" "daily" {
  name        = var.job_name
  description = "bronze -> silver -> gold -> Parquet export. Wheel pinned to ${var.wheel_version}."

  # Serverless. Free Edition offers no other compute, and no DLT.
  environment {
    environment_key = "default"

    spec {
      client = "1"

      # Pinned by exact filename. There is no way to express "latest" here, which
      # is the point (global rule 1).
      dependencies = [local.wheel]
    }
  }

  dynamic "task" {
    for_each = local.tasks

    content {
      task_key        = task.key
      environment_key = "default"

      dynamic "depends_on" {
        for_each = task.value

        content {
          task_key = depends_on.value
        }
      }

      python_wheel_task {
        package_name = local.package_name
        entry_point  = task.key
      }
    }
  }

  # A second concurrent run would have two writers doing MERGE against the same
  # silver tables. Queue instead.
  max_concurrent_runs = 1

  queue {
    enabled = true
  }

  schedule {
    quartz_cron_expression = var.job_schedule_expression
    timezone_id            = "UTC"
    pause_status           = var.job_schedule_enabled ? "UNPAUSED" : "PAUSED"
  }
}
