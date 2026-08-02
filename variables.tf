variable "aws_region" {
  description = <<-EOT
    AWS region. Single region by design; Free Edition gives one workspace.

    us-east-2 is not arbitrary: the Databricks metastore is
    `metastore_aws_us_east_2`, and on Free Edition the compute is serverless in
    Databricks' own account. Putting these buckets anywhere else means every
    byte repo 4 exports and repo 5 reads crosses a region boundary, paying
    transfer charges and latency for nothing.
  EOT
  type        = string
  default     = "us-east-2"
}

variable "aws_profile" {
  description = <<-EOT
    Named AWS CLI profile for local runs. Leave empty in CI, which authenticates
    by assuming an OIDC role and has no profiles configured.
  EOT
  type        = string
  default     = ""
}

variable "allowed_account_ids" {
  description = <<-EOT
    Terraform refuses to run if the resolved credentials belong to any other
    account. This is the cheapest possible protection against provisioning the
    whole project into the wrong AWS account.
  EOT
  type        = list(string)
  default     = []
}

variable "env" {
  description = <<-EOT
    Environment name, used only as a tag and as a catalog prefix if this project
    ever grows a second environment. Terraform workspaces are deliberately NOT
    used: Free Edition provides one workspace and one metastore, so environment
    separation would have to be by catalog name, not by state file.
  EOT
  type        = string
  default     = "dev"
}

variable "github_owner" {
  description = "GitHub owner used to scope the OIDC trust policies."
  type        = string
  default     = "Dark417"
}

# --- Databricks -------------------------------------------------------------

variable "databricks_host" {
  description = "Databricks workspace URL, e.g. https://dbc-xxxx.cloud.databricks.com"
  type        = string

  validation {
    condition     = startswith(var.databricks_host, "https://") && !strcontains(var.databricks_host, "REPLACE-ME")
    error_message = "databricks_host must be the real https:// workspace URL. Find it with `databricks auth env` or in the browser address bar."
  }
}

variable "databricks_pat_secret_name" {
  description = "Secrets Manager name holding the workspace PAT. Value created by hand (§9.2)."
  type        = string
  default     = "/edgar-lakehouse/databricks/pat"
}

variable "workspace_principal" {
  description = <<-EOT
    Principal receiving catalog and volume grants. Empty disables the grants
    entirely, which is the default because the value is an identity and this repo
    is public — supply it from envs/dev.local.tfvars.

    It must be an ACCOUNT-level identity, not a workspace group. Learned the hard
    way on 2026-08-01: `databricks groups list` reports `admins` and `users`, but
    both are workspace-local SCIM groups and Unity Catalog rejects them with
    "Could not find principal with name users". The commonly-cited "account users"
    group does not exist on Free Edition either. What does resolve is an account
    user's email address.

    Note these grants are close to a no-op on a single-user workspace: the catalog
    owner already holds every privilege implicitly. They are kept because they
    document intended access, and because a second identity would need them.
  EOT
  type        = string
  default     = ""
}

variable "warehouse_id" {
  description = <<-EOT
    SQL warehouse id, published to SSM for repo 1 (Liquibase JDBC target) and
    repo 5. Free Edition creates a warehouse for you; this is not Terraform's to
    create, so it is an input, not a resource.
  EOT
  type        = string
}

variable "pipelines_wheel_version" {
  description = <<-EOT
    Exact version of the repo-4 wheel each job task installs. Pinned with `==`
    semantics by construction — there is no way to express "latest" here, which
    is the point (global rule 1).
  EOT
  type        = string
}

variable "pipelines_wheel_dir" {
  description = <<-EOT
    Volume directory that repo 4's CI uploads its wheel into. Job tasks install
    from here because the package is private and not on PyPI.
  EOT
  type        = string
  default     = "/Volumes/edgar/landing/wheels"
}

# --- Ingest / SEC -----------------------------------------------------------

variable "sec_user_agent_secret_name" {
  description = <<-EOT
    Secrets Manager name holding the SEC User-Agent string. SEC returns 403 to
    clients without a contact email, so this is an auth credential in practice.
  EOT
  type        = string
  default     = "/edgar-lakehouse/sec/user-agent"
}

variable "ingest_image_tag" {
  description = <<-EOT
    Image tag for the repo-3 container. Resolved to an immutable digest by the
    aws_ecr_image data source before it reaches the task definition, so a
    re-pushed tag can never silently change what runs.
  EOT
  type        = string
  default     = "latest"
}

variable "ingest_image_digest" {
  description = <<-EOT
    Immutable image digest ("sha256:..."), supplied by repo 3's CI at deploy
    time. When empty the task definition falls back to the tag, which is only
    correct during bootstrap: on the very first apply the ECR repository is
    empty, and an `aws_ecr_image` data source would hard-fail the plan rather
    than degrade. Repo 3 passes -var ingest_image_digest=... on every deploy.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.ingest_image_digest == "" || startswith(var.ingest_image_digest, "sha256:")
    error_message = "ingest_image_digest must be empty or a \"sha256:...\" digest."
  }
}

variable "ingest_env" {
  description = "Non-secret environment variables for the ingest task."
  type        = map(string)
  default     = {}
}

variable "landing_mode" {
  description = <<-EOT
    ADR-001 outcome: which path Auto Loader reads. Defaults to "volume", the safe
    branch, until the S3-readability probe in repo 1 docs/ADR-001 is run.
  EOT
  type        = string
  default     = "volume"

  validation {
    condition     = contains(["s3", "volume"], var.landing_mode)
    error_message = "landing_mode must be exactly \"s3\" or \"volume\" (ADR-001)."
  }
}

variable "contracts_version" {
  description = "Pinned repo-1 wheel version, published to SSM for repos 3-5."
  type        = string
  default     = "0.1.0"
}

# --- Safety switches --------------------------------------------------------

variable "schedule_enabled" {
  description = <<-EOT
    Rule 4: defaults to false. An enabled schedule pointing at unproven code
    burns the Free Edition daily quota and fills S3 with garbage. A human flips
    this only after repo 4 has run successfully by hand (§9.9).
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Explicit CloudWatch retention. The default of \"never expire\" is a slow bill."
  type        = number
  default     = 14
}

variable "ia_transition_days" {
  description = "Days before S3 objects transition to STANDARD_IA."
  type        = number
  default     = 90
}
