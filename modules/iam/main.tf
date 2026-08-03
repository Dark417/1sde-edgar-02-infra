data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  region    = data.aws_region.current.name
  partition = data.aws_partition.current.partition

  raw_bucket_arn = "arn:${local.partition}:s3:::${var.raw_bucket}"

  # No serving_bucket_arn. Repo 5's read access to the serving bucket is granted
  # resource-side, by the bucket policy in modules/storage, not identity-side
  # here — so IAM never needs that ARN.

  # Constructed rather than taken as a module output. The names are deterministic
  # locals in the root module, so these ARNs are knowable before the resources
  # exist — which is what lets IAM be created before compute (see main.tf).
  log_group_arn = "arn:${local.partition}:logs:${local.region}:${local.account}:log-group:${var.log_group_name}"
  task_def_arn  = "arn:${local.partition}:ecs:${local.region}:${local.account}:task-definition/${var.ecs_family}"
  cluster_arn   = "arn:${local.partition}:ecs:${local.region}:${local.account}:cluster/${var.ecs_cluster}"

  ssm_path_arn = "arn:${local.partition}:ssm:${local.region}:${local.account}:parameter/edgar-lakehouse/*"

  # The contracts wheel lives under wheels/ in the Terraform state bucket
  # (AGENTS.md §9.4). That bucket is created by hand during bootstrap and is not
  # Terraform-managed, so access is granted identity-side rather than by bucket
  # policy. Derived from the account id rather than taken as a required input,
  # since the bootstrap script builds the name the same way.
  artifacts_bucket_arn = var.artifacts_bucket != "" ? "arn:${local.partition}:s3:::${var.artifacts_bucket}" : "arn:${local.partition}:s3:::${var.name_prefix}-tfstate-${local.account}"
  wheels_prefix        = "wheels/*"

  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC federation
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # No thumbprint_list. Since 2023 AWS validates token.actions.githubusercontent.com
  # against a trusted root CA and ignores any thumbprint supplied for it, so
  # pinning one is dead weight that rots: GitHub has rotated its intermediate
  # before, and hardcoded thumbprints are exactly what broke people when it did.
  # The attribute is optional in the provider; leaving it out is the maintained
  # path.
}

data "aws_iam_policy_document" "oidc_trust" {
  for_each = toset(var.github_repos)

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to one repository. A bare "*" here would let any repository in any
    # GitHub account assume this role — that is the finding, not the ":*" suffix,
    # which merely allows any branch or tag WITHIN this repository.
    #
    # TWO patterns, because GitHub now issues ID-qualified subject claims. The
    # observed claim from a real run was:
    #
    #   repo:Dark417@8498516/1sde-edgar-02-infra@1318930730:pull_request
    #
    # not the documented `repo:owner/name:ref`. The numeric owner and repository
    # IDs are appended precisely so that renaming a repo cannot be used to
    # inherit another repo's trust — which matters here, since these repos have
    # already been renamed twice. Matching only the classic form fails closed
    # with "Not authorized to perform sts:AssumeRoleWithWebIdentity", which names
    # neither the claim nor the mismatch and is a genuinely awful thing to debug.
    #
    # `@*` widens only the numeric ID; the owner and repository NAMES stay
    # pinned, so this is no weaker than the single-pattern version.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${each.value}:*",
        "repo:${var.github_owner}@*/${each.value}@*:*",
      ]
    }
  }
}

resource "aws_iam_role" "oidc" {
  for_each = toset(var.github_repos)

  name               = "${each.value}-ci"
  description        = "GitHub Actions OIDC role for ${var.github_owner}/${each.value}."
  assume_role_policy = data.aws_iam_policy_document.oidc_trust[each.value].json
}

# ---------------------------------------------------------------------------
# Terraform execution role — assumed by the human and by repo 2's CI
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "terraform_trust" {
  statement {
    effect = "Allow"

    # sts:TagSession alongside sts:AssumeRole. aws-actions/configure-aws-credentials
    # attaches session tags (repository, workflow, actor, ref) on every assume,
    # and when role-chaining that means the *source* role must be permitted to
    # tag. Without it, chaining fails with "not authorized to perform:
    # sts:TagSession", which reads like a trust problem and is not one.
    #
    # Permitting it rather than disabling tagging is the better trade: those tags
    # land in CloudTrail, so an audit of who applied what shows the workflow and
    # commit rather than an anonymous assumed-role session.
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type = "AWS"
      identifiers = [
        "arn:${local.partition}:iam::${local.account}:root",
        aws_iam_role.oidc["1sde-edgar-02-infra"].arn,
      ]
    }
  }
}

resource "aws_iam_role" "terraform" {
  name               = "${var.name_prefix}-tf"
  description        = "Terraform execution role. The only principal permitted to delete from the raw zone."
  assume_role_policy = data.aws_iam_policy_document.terraform_trust.json
}

#trivy:ignore:AWS-0345
# The s3:* finding is accepted for this role only. It is the provisioning
# identity: it creates and destroys the buckets, so it cannot be scoped to ARNs
# that do not exist until it makes them. Blast radius is bounded instead by the
# trust policy, which admits only the account root and repo 2's CI role, and by
# the raw bucket's own policy, which denies deletes to everyone else.
data "aws_iam_policy_document" "terraform" {
  # Service-scoped rather than PowerUserAccess. Rule 8 forbids broad AWS managed
  # policies, so this enumerates the services this project actually provisions.
  statement {
    sid    = "ProvisionProjectServices"
    effect = "Allow"

    actions = [
      "s3:*",
      "ecr:*",
      "ecs:*",
      "scheduler:*",
      "logs:*",
      "ssm:*",
      "iam:*",
      "ec2:Describe*",
      # GetResourcePolicy is not optional despite looking like it. The
      # `aws_secretsmanager_secret` DATA SOURCE reads the secret's resource
      # policy as part of a normal read, so every plan needs it. Its absence was
      # invisible until CI ran: locally this executes as an administrator role,
      # and CI was the first identity to exercise this policy as written.
      # ListSecretVersionIds is needed for the same reason on the version lookup.
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
    ]

    # allow-wildcard-resource: this role provisions the project's infrastructure,
    # including resources whose ARNs do not exist until it creates them. Scoping
    # by ARN is impossible for a creating principal. Blast radius is bounded by
    # the action list above and by the role's trust policy, which admits only the
    # account root and repo 2's CI.
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "terraform" {
  name   = "provision"
  role   = aws_iam_role.terraform.id
  policy = data.aws_iam_policy_document.terraform.json
}

# Repo 2's CI does not carry provisioning rights itself; it assumes the role
# above. One privileged identity is easier to audit than two.
data "aws_iam_policy_document" "infra_ci_assume" {
  statement {
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.terraform.arn]
  }
}

resource "aws_iam_role_policy" "infra_ci_assume" {
  name   = "assume-terraform-role"
  role   = aws_iam_role.oidc["1sde-edgar-02-infra"].id
  policy = data.aws_iam_policy_document.infra_ci_assume.json
}

# ---------------------------------------------------------------------------
# Ingest task role — what repo 3's container runs as
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ecs:${local.region}:${local.account}:*"]
    }
  }
}

resource "aws_iam_role" "ingest_task" {
  name               = "1sde-edgar-03-ingest-task"
  description        = "Application role for the ingest container."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "ingest_task" {
  # PutObject on the raw prefix and nothing else. Deliberately NOT s3:*, NOT the
  # bare bucket ARN, and NOT DeleteObject — the raw zone is immutable and the
  # task has no business deleting from it (rule 6). The bucket policy denies
  # deletes independently, so this is defence in depth rather than the only gate.
  statement {
    sid       = "WriteRawZoneOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.raw_bucket_arn}/*"]
  }

  # Global rule 3: repos resolve config as env var -> SSM -> fail. Without this
  # the container cannot read its own configuration.
  statement {
    sid    = "ReadProjectConfig"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = [local.ssm_path_arn]
  }

  statement {
    sid       = "ReadNamedSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }

  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${local.log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "ingest_task" {
  name   = "ingest-task"
  role   = aws_iam_role.ingest_task.id
  policy = data.aws_iam_policy_document.ingest_task.json
}

# ---------------------------------------------------------------------------
# ECS execution role — what the ECS agent uses to start the task
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ingest_execution" {
  name               = "1sde-edgar-03-ingest-execution"
  description        = "ECS agent role: pulls the image and injects secrets."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# NOT attached: arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy.
#
# Rule 8 permits that managed policy by name, but attaching it here would be a
# least-privilege regression. Its actual document (verified against the API) is a
# single statement granting ecr:GetAuthorizationToken, ecr:BatchGetImage,
# ecr:GetDownloadUrlForLayer, ecr:BatchCheckLayerAvailability, logs:CreateLogStream
# and logs:PutLogEvents on Resource "*".
#
# The inline policy below grants exactly those actions, but scoped to this
# project's ECR repository and this task's log group. Attaching the managed
# policy alongside it would re-grant them account-wide and make the scoping
# decorative. The inline policy is a strict superset of what the task needs, so
# nothing is lost by omitting the managed one.
data "aws_iam_policy_document" "ingest_execution" {
  statement {
    sid    = "PullIngestImage"
    effect = "Allow"

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]

    resources = [var.ecr_repository_arn]
  }

  statement {
    sid     = "EcrAuth"
    effect  = "Allow"
    actions = ["ecr:GetAuthorizationToken"]

    # allow-wildcard-resource: GetAuthorizationToken is an account-level call
    # that AWS does not associate with any repository ARN. It returns only a
    # short-lived token; the pull itself is scoped by the statement above.
    resources = ["*"]
  }

  # Required so ECS can resolve `secrets[].valueFrom` before the container starts.
  # The task role's copy of this is for the application's own runtime fetches.
  statement {
    sid       = "InjectSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }

  statement {
    sid    = "WriteTaskLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${local.log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "ingest_execution" {
  name   = "ingest-execution"
  role   = aws_iam_role.ingest_execution.id
  policy = data.aws_iam_policy_document.ingest_execution.json
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name_prefix}-scheduler"
  description        = "EventBridge Scheduler role: starts the daily ingest task."
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid     = "RunIngestTask"
    effect  = "Allow"
    actions = ["ecs:RunTask"]

    # Revisions are appended to the family ARN, so the wildcard here is a
    # revision wildcard, not a resource-type wildcard.
    resources = ["${local.task_def_arn}:*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.cluster_arn]
    }
  }

  statement {
    sid     = "PassTaskRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]

    resources = [
      aws_iam_role.ingest_task.arn,
      aws_iam_role.ingest_execution.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "run-ingest"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# ---------------------------------------------------------------------------
# Per-repo CI permissions beyond bare federation
# ---------------------------------------------------------------------------

# Repo 3 pushes the ingest image and registers new task definition revisions.
data "aws_iam_policy_document" "ingest_ci" {
  statement {
    sid    = "PushImage"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]

    resources = [var.ecr_repository_arn]
  }

  statement {
    sid     = "EcrAuth"
    effect  = "Allow"
    actions = ["ecr:GetAuthorizationToken"]

    # allow-wildcard-resource: account-level call with no repository ARN.
    resources = ["*"]
  }

  statement {
    sid    = "ReadProjectConfig"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = [local.ssm_path_arn]
  }

  statement {
    sid    = "UpdateTaskDefinition"
    effect = "Allow"

    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
    ]

    # allow-wildcard-resource: neither action supports resource-level scoping —
    # Describe addresses a family by name, Register creates the new revision.
    resources = ["*"]
  }

  # Registering a revision re-submits the task and execution role ARNs, which
  # requires permission to pass exactly those two roles — and only to ECS.
  statement {
    sid     = "PassTaskRolesToEcs"
    effect  = "Allow"
    actions = ["iam:PassRole"]

    resources = [
      aws_iam_role.ingest_task.arn,
      aws_iam_role.ingest_execution.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ingest_ci" {
  name   = "push-ingest-image"
  role   = aws_iam_role.oidc["1sde-edgar-03-ingest"].id
  policy = data.aws_iam_policy_document.ingest_ci.json
}

# Repos 1, 4 and 5 only need to read the published config interface. Repo 5 also
# reads the serving export; that grant lives in the bucket policy.
data "aws_iam_policy_document" "config_reader" {
  statement {
    sid    = "ReadProjectConfig"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = [local.ssm_path_arn]
  }
}

resource "aws_iam_role_policy" "config_reader" {
  for_each = toset([
    "1sde-edgar-01-contracts",
    "1sde-edgar-04-pipelines",
    "1sde-edgar-05-serving",
    # Repo 6 reads /edgar-lakehouse/chat/* on every start: the kill switch, the
    # model pin, and the daily token ceiling. Without this its CI cannot even
    # resolve which model to call.
    "1sde-edgar-06-chatbot",
  ])

  name   = "read-project-config"
  role   = aws_iam_role.oidc[each.value].id
  policy = data.aws_iam_policy_document.config_reader.json
}

# ---------------------------------------------------------------------------
# Contracts wheel distribution
#
# Every repo installs edgar-lakehouse-contracts from s3://<state-bucket>/wheels/
# because the package is private and not on PyPI (pip cannot read s3:// URLs, so
# CI does an `aws s3 cp` first). Repo 1 builds and publishes it; everyone else,
# including repo 2's own test job, only reads.
#
# Without these, every repo's CI fails at the install step with AccessDenied —
# a gap that was invisible until the roles were audited against what the
# workflows actually run.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "wheels_read" {
  statement {
    sid       = "ListWheelsPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.artifacts_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["wheels/*", "wheels"]
    }
  }

  statement {
    sid       = "ReadWheels"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.artifacts_bucket_arn}/${local.wheels_prefix}"]
  }
}

resource "aws_iam_role_policy" "wheels_read" {
  for_each = toset(var.github_repos)

  name   = "read-contracts-wheel"
  role   = aws_iam_role.oidc[each.value].id
  policy = data.aws_iam_policy_document.wheels_read.json
}

# Repo 1 is the only publisher. Deliberately no DeleteObject: a published wheel
# version is immutable, and overwriting one silently changes what every other
# repo installs for a version they pinned with ==.
data "aws_iam_policy_document" "wheels_write" {
  statement {
    sid       = "PublishWheels"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.artifacts_bucket_arn}/${local.wheels_prefix}"]
  }
}

resource "aws_iam_role_policy" "wheels_write" {
  name   = "publish-contracts-wheel"
  role   = aws_iam_role.oidc["1sde-edgar-01-contracts"].id
  policy = data.aws_iam_policy_document.wheels_write.json
}

# ---------------------------------------------------------------------------
# Bedrock inference for the chatbot (repo 6)
#
# Bedrock has no API key: the caller's AWS identity IS the credential, so this
# policy is the whole of "the chatbot can talk to a model". Two things are
# scoped deliberately:
#
#   * Actions are InvokeModel and InvokeModelWithResponseStream only. Nothing
#     here may create, tune, delete or share a model.
#   * Resources are Anthropic and Amazon foundation models plus the matching
#     cross-region inference profiles, in this partition, not "*". The
#     candidate list in repo 6 config.py is Claude first with Nova as the
#     fallback, and the profile ARNs are required because every id the app
#     actually calls is an inference profile (us.anthropic..., us.amazon...),
#     which resolves to the underlying model in another region.
#
# Anthropic models additionally need the one-time account use-case form; that
# is an account fact, not IAM, and it was submitted for 806168459926 on
# 2026-08-02. IAM alone cannot grant it and cannot revoke it.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    sid    = "InvokeFoundationModels"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/anthropic.*",
      "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/amazon.nova-*",
      "arn:${data.aws_partition.current.partition}:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.*",
      "arn:${data.aws_partition.current.partition}:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/us.amazon.nova-*",
    ]
  }

  # Listing is how the app discovers which models this account can actually
  # invoke (config.pick_model probes the candidate list). It is read-only and
  # carries no model access of its own.
  statement {
    sid       = "DiscoverModels"
    effect    = "Allow"
    actions   = ["bedrock:ListFoundationModels", "bedrock:ListInferenceProfiles"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bedrock_invoke" {
  for_each = toset(["1sde-edgar-06-chatbot"])

  name   = "invoke-bedrock-models"
  role   = aws_iam_role.oidc[each.value].id
  policy = data.aws_iam_policy_document.bedrock_invoke.json
}
