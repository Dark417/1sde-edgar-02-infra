# Dev environment inputs — the PUBLIC, non-identifying half.
#
# This repo is public, so three values are deliberately NOT here:
#
#   databricks_host        the workspace URL
#   warehouse_id           the SQL warehouse id
#   allowed_account_ids    the AWS account id
#
# They are OMITTED rather than set to placeholders. That distinction matters:
# `-var-file` outranks `TF_VAR_*` environment variables in Terraform's precedence
# order, so a placeholder left here would silently override the real value CI
# injects and fail with a confusing "account ID not allowed". An absent variable
# fails loudly and immediately instead.
#
# Supply them one of two ways:
#
#   locally   envs/dev.local.tfvars  (gitignored), passed as a SECOND -var-file
#             after this one, since the later -var-file wins:
#               terraform plan -var-file=envs/dev.tfvars \
#                              -var-file=envs/dev.local.tfvars
#
#   in CI     TF_VAR_databricks_host / TF_VAR_warehouse_id /
#             TF_VAR_allowed_account_ids, from GitHub secrets. Nothing here
#             overrides them because they are not declared in this file.

# Exact repo-4 wheel version. Bump this to roll the job forward; never "latest".
pipelines_wheel_version = "0.1.0"

# Matches the Databricks metastore region (metastore_aws_us_east_2).
aws_region = "us-east-2"

# Local runs assume OrganizationAccountAccessRole via this profile. CI overrides
# it with `-var aws_profile=` and uses OIDC federation instead.
aws_profile = "edgar"
env         = "dev"

# ADR-001 is unresolved. "volume" is the safe branch: it works whether or not the
# workspace can read S3 directly. Flip to "s3" only after running the probe in
# repo 1 docs/ADR-001-landing-transport.md.
landing_mode = "volume"

# Pinned repo-1 wheel. Must match the version actually published to
# s3://<state-bucket>/wheels/ — repos 3-5 read this from SSM and install exactly
# it, so a stale pin here is an install failure everywhere downstream.
contracts_version = "1.1.0"

# Rule 4. Stays false until repo 4 has run successfully by hand (§9.9).
schedule_enabled = false
