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
contracts_version = "1.4.1"

# Rule 4 satisfied: repo 4 has now run end to end by hand against logical_date
# 2026-07-31 -- bronze, silver, gold and serving_export all SUCCESS, and the export
# published to s3://edgar-lake-serving. Repo 4's bundle schedule is UNPAUSED to match,
# so the daily chain runs unattended: this lands the day's filings at 06:00 UTC and the
# pipeline picks them up.
#
# Note the two schedules are independent -- there is no completion signal between them.
# The pipeline reads whatever is in the landing zone at its own trigger time.
schedule_enabled = true

# The chatbot host is real and running, so the committed config says so. It was
# created from a gitignored local tfvars, which meant every plan run from a
# different checkout wanted to destroy it -- a plan showing "10 to destroy"
# against a live instance is exactly the drift the destroy-guard exists to catch.
# ~$6.13/month for a t4g.micro; the public IPv4 is billed either way.
deploy_chatbot = true

# Repo 5's API and UI are co-hosted on that same instance rather than given
# their own. It already holds the two permissions repo 5 needs -- s3:GetObject
# on the serving prefix and ssm:GetParameter -- so a second host would have paid
# $5-7/month to duplicate an IAM role and sit idle. The cost is that repo 5's
# uptime is coupled to this box; repo 5 is containerised, so moving it out later
# is a runtime change, not a rewrite.
