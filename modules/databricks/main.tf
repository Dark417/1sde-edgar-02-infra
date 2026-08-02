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
# All three grant resources are conditional on a principal being supplied.
# Unity Catalog requires an ACCOUNT-level identity here; the workspace groups
# `admins` and `users` that `databricks groups list` reports are workspace-local
# SCIM groups and fail with "Could not find principal with name users".
resource "databricks_grants" "catalog" {
  count = var.workspace_principal != "" ? 1 : 0

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
  count = var.workspace_principal != "" ? 1 : 0

  volume = databricks_volume.landing_edgar.id

  grant {
    principal  = var.workspace_principal
    privileges = ["READ_VOLUME", "WRITE_VOLUME"]
  }
}

resource "databricks_grants" "wheels_volume" {
  count = var.workspace_principal != "" ? 1 : 0

  volume = databricks_volume.wheels.id

  grant {
    principal  = var.workspace_principal
    privileges = ["READ_VOLUME", "WRITE_VOLUME"]
  }
}

# ---------------------------------------------------------------------------
# NO databricks_job HERE. The job definition belongs to repo 4's Asset Bundle.
#
# This module owned a `databricks_job.daily` until 2026-08-02. It was removed
# because it could not work, and the reason generalises:
#
# An ECS task definition references its image by URI, so repo 2 can declare the
# container without knowing anything about the code inside it. A Databricks job
# has no such seam — its tasks name the package, the entry point, the parameters
# and the dependency edges. That IS the code's interface, so declaring it here
# means restating repo 4's internals from another repository.
#
# Restating them went exactly as you would expect. Every field was wrong:
#
#   declared here                          repo 4 actually ships
#   -------------------------------------  -----------------------------------
#   wheel edgar_lakehouse_pipelines-*.whl  edgar_pipelines
#   package_name edgar_lakehouse_pipelines edgar_pipelines
#   6 entry points (bronze_all, ...)       one dispatcher, `edgar-pipelines <task>`
#   6 tasks                                4 (bronze_ingest ... serving_export)
#
# The job was live and would have failed on its first run. Asset Bundles exist
# precisely so the task graph lives beside the code that implements it.
#
# What this module still owns for repo 4: the `wheels` volume below, which is
# where the bundle publishes its artifact.
# ---------------------------------------------------------------------------