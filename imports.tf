# ---------------------------------------------------------------------------
# Adopting objects that already exist.
#
# The catalog, its four schemas and the landing volume were created by hand
# through the SQL API on 2026-08-01, before this Terraform existed, so that repo
# 1's `liquibase update` had somewhere to build its 13 tables. Terraform is the
# declared owner of those containers (AGENTS.md §1), so it has to adopt them
# rather than create them — without these blocks the first apply fails with
# "Catalog 'edgar' already exists" and leaves you reaching for the console.
#
# Import blocks are idempotent: once a resource is in state, Terraform ignores
# the block. They can be deleted after the first successful apply, and SHOULD be
# once the state file is established — an import block for an object that no
# longer exists upstream is a confusing plan-time failure for whoever inherits
# this.
#
# Deliberately NOT imported:
#   - the `wheels` volume, which this repo genuinely creates
#   - `edgar.default` and `edgar.information_schema`, which Databricks creates
#     automatically and Terraform does not manage
#   - the 13 tables, which belong to Liquibase (§1). Importing a table here
#     would give it two owners and a `terraform destroy` that silently drops
#     something Liquibase still thinks it manages.
# ---------------------------------------------------------------------------

import {
  to = module.databricks.databricks_catalog.this
  id = "edgar"
}

import {
  to = module.databricks.databricks_schema.this["landing"]
  id = "edgar.landing"
}

import {
  to = module.databricks.databricks_schema.this["bronze"]
  id = "edgar.bronze"
}

import {
  to = module.databricks.databricks_schema.this["silver"]
  id = "edgar.silver"
}

import {
  to = module.databricks.databricks_schema.this["gold"]
  id = "edgar.gold"
}

import {
  to = module.databricks.databricks_volume.landing_edgar
  id = "edgar.landing.edgar"
}
