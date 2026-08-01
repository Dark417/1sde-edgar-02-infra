# Dev environment inputs.
#
# The values below come from your live workspace and from repo 4's build. These
# are identifiers, not secrets — the PAT lives in Secrets Manager and is read as
# a data source, never written here.

# Verified live 2026-08-01 via `databricks catalogs list`.
databricks_host = "https://dbc-6e85f573-bc49.cloud.databricks.com"

# SQL Warehouses -> your warehouse -> Connection details -> the id in the HTTP path.
# Free Edition creates this for you; Terraform does not own it.
warehouse_id = "733dc896c4c3751c"

# Exact repo-4 wheel version. Bump this to roll the job forward; never "latest".
pipelines_wheel_version = "0.1.0"

# --- Values with sane defaults, restated here to make them visible ------------

# Matches the Databricks metastore region (metastore_aws_us_east_2).
aws_region = "us-east-2"

# The dedicated member account created under the organization for this project.
# Terraform hard-fails if the credentials in your shell resolve anywhere else,
# so a forgotten --profile is a clean error rather than resources built in the
# management account alongside unrelated SageMaker work.
allowed_account_ids = ["806168459926"]

# Local runs assume OrganizationAccountAccessRole via this profile. CI overrides
# it to "" and uses OIDC federation instead.
aws_profile = "edgar"
env         = "dev"

# ADR-001 is unresolved. "volume" is the safe branch: it works whether or not the
# workspace can read S3 directly. Flip to "s3" only after running the probe in
# repo 1 docs/ADR-001-landing-transport.md.
landing_mode = "volume"

# Pinned repo-1 wheel.
contracts_version = "0.1.0"

# Rule 4. Stays false until repo 4 has run successfully by hand (§9.9).
schedule_enabled = false
