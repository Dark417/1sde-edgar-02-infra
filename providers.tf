terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Local runs use a named profile that assumes into the dedicated member
  # account. CI passes null here and authenticates via OIDC instead, so the
  # profile must not be baked in.
  profile = var.aws_profile != "" ? var.aws_profile : null

  # The guard that matters most in a multi-account setup. Without it, running
  # terraform with the wrong credentials in your shell provisions this entire
  # project into whatever account you happened to be pointing at — and the first
  # you would know is a bill and a pile of resources in the wrong place.
  # With it, Terraform refuses to do anything at all.
  allowed_account_ids = var.allowed_account_ids

  # Rule 10: tag everything. Setting this here means no module has to remember.
  default_tags {
    tags = local.tags
  }
}

# No aws_caller_identity / aws_partition here. They were added for constructing
# ARNs at root, but the root module builds none — every ARN is constructed inside
# the module that needs it, from that module's own lookups. tflint caught both as
# unused on the first CI run.

# Secret VALUES are created by hand (AGENTS.md §9.2) and referenced as data
# sources. Writing an `aws_secretsmanager_secret_version` *resource* would put the
# plaintext PAT into Terraform state — see rule 5.
data "aws_secretsmanager_secret" "databricks_pat" {
  name = var.databricks_pat_secret_name
}

data "aws_secretsmanager_secret_version" "databricks_pat" {
  secret_id = data.aws_secretsmanager_secret.databricks_pat.id
}

data "aws_secretsmanager_secret" "sec_user_agent" {
  name = var.sec_user_agent_secret_name
}

# WORKSPACE-level authentication only. Free Edition exposes no account API, so
# there is no account-scoped provider alias anywhere in this repo (rule 1).
provider "databricks" {
  host  = var.databricks_host
  token = data.aws_secretsmanager_secret_version.databricks_pat.secret_string
}
