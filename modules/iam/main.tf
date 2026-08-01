data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  region    = data.aws_region.current.name
  partition = data.aws_partition.current.partition

  raw_bucket_arn     = "arn:${local.partition}:s3:::${var.raw_bucket}"
  serving_bucket_arn = "arn:${local.partition}:s3:::${var.serving_bucket}"

  # Constructed rather than taken as a module output. The names are deterministic
  # locals in the root module, so these ARNs are knowable before the resources
  # exist — which is what lets IAM be created before compute (see main.tf).
  log_group_arn = "arn:${local.partition}:logs:${local.region}:${local.account}:log-group:${var.log_group_name}"
  task_def_arn  = "arn:${local.partition}:ecs:${local.region}:${local.account}:task-definition/${var.ecs_family}"
  cluster_arn   = "arn:${local.partition}:ecs:${local.region}:${local.account}:cluster/${var.ecs_cluster}"

  ssm_path_arn = "arn:${local.partition}:ssm:${local.region}:${local.account}:parameter/edgar-lakehouse/*"

  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC federation
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
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
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${each.value}:*"]
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
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:${local.partition}:iam::${local.account}:root",
        aws_iam_role.oidc["1sde-databricks-edgar-02-infra"].arn,
      ]
    }
  }
}

resource "aws_iam_role" "terraform" {
  name               = "${var.name_prefix}-tf"
  description        = "Terraform execution role. The only principal permitted to delete from the raw zone."
  assume_role_policy = data.aws_iam_policy_document.terraform_trust.json
}

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
      "dynamodb:*",
      "ec2:Describe*",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
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
  role   = aws_iam_role.oidc["1sde-databricks-edgar-02-infra"].id
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
  name               = "1sde-databricks-edgar-03-ingest-task"
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
  name               = "1sde-databricks-edgar-03-ingest-execution"
  description        = "ECS agent role: pulls the image and injects secrets."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# The one AWS managed policy rule 8 permits by name.
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.ingest_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

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
}

resource "aws_iam_role_policy" "ingest_ci" {
  name   = "push-ingest-image"
  role   = aws_iam_role.oidc["1sde-databricks-edgar-03-ingest"].id
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
    "1sde-databricks-edgar-01-contracts",
    "1sde-databricks-edgar-04-pipelines",
    "1sde-databricks-edgar-05-serving",
  ])

  name   = "read-project-config"
  role   = aws_iam_role.oidc[each.value].id
  policy = data.aws_iam_policy_document.config_reader.json
}
