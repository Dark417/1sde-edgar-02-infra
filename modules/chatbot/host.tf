# ---------------------------------------------------------------------------
# The chatbot host (repo 6), behind var.deploy_chatbot.
#
# WHY EC2 AND NOT LIGHTSAIL. Lightsail is $3.42/month cheaper for the same 1 GB
# and bundles the disk, the IPv4 address and 2 TB of transfer -- genuinely the
# better deal on paper. It was the recommendation until one fact killed it:
# **Lightsail instances cannot assume an IAM role.** `create-instances` has no
# instance-profile parameter and the API has no equivalent, so the only way to
# give a Lightsail box Bedrock access is to write a long-lived IAM access key
# onto a public-facing host.
#
# This project spent a day retiring exactly that: an 18-month-old key with no
# MFA. Putting a fresh one on an internet-facing demo to save $3.42/month would
# undo the reasoning. EC2 supports instance profiles, so the host holds no
# credential at all -- the role is assumed from instance metadata and rotates
# itself.
#
# WHY NOT FARGATE. An always-on Fargate service needs an ALB to be reachable on
# a stable address (~$16/month for the load balancer alone), which triples the
# bill for one container that never scales.
#
# WHY t4g.micro AND NOT nano. Measured, not guessed: the app is 424 MB RSS with
# the data loaded (langchain-aws is +59 MB of that, Streamlit +29 MB). Plus the
# OS that is ~545 MB, so a 512 MB host swaps or is OOM-killed mid-answer.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023_arm64" {
  count = var.deploy_chatbot ? 1 : 0
  # Canonical AL2023 arm64 AMI, resolved at apply time. Hardcoding an AMI id
  # pins the host to an image that stops receiving patches.
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_vpc" "default" {
  count   = var.deploy_chatbot && var.vpc_id == "" ? 1 : 0
  default = true
}

locals {
  chatbot_vpc_id = var.deploy_chatbot ? (
    var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
  ) : ""
}

# --- identity: a role, never a key ----------------------------------------
data "aws_iam_policy_document" "chatbot_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chatbot" {
  count              = var.deploy_chatbot ? 1 : 0
  name               = "edgar-chatbot-host"
  assume_role_policy = data.aws_iam_policy_document.chatbot_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "chatbot_host" {
  # Bedrock: invoke only, and only the model families the app can select.
  # Scoped to inference profiles as well as base models because every id the
  # app actually calls is a profile (us.anthropic...), which resolves to the
  # underlying model in another region.
  statement {
    sid    = "InvokeModels"
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

  # The exported gold Parquet, read once at boot into a local DuckDB file.
  # GetObject on the v1 prefix only; the host has no reason to write, and the
  # raw zone is not readable from here at all.
  statement {
    sid       = "ReadServingExport"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.serving_bucket}/v1/*"]
  }

  statement {
    sid       = "ListServingExport"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.serving_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["v1/*"]
    }
  }

  # The kill switch, the model pin and the token ceiling.
  statement {
    sid       = "ReadChatConfig"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/edgar-lakehouse/chat/*"]
  }
}

resource "aws_iam_role_policy" "chatbot_host" {
  count  = var.deploy_chatbot ? 1 : 0
  name   = "chatbot-host"
  role   = aws_iam_role.chatbot[0].id
  policy = data.aws_iam_policy_document.chatbot_host.json
}

resource "aws_iam_instance_profile" "chatbot" {
  count = var.deploy_chatbot ? 1 : 0
  name  = "edgar-chatbot-host"
  role  = aws_iam_role.chatbot[0].name
  tags  = var.tags
}

# --- network ---------------------------------------------------------------
resource "aws_security_group" "chatbot" {
  count       = var.deploy_chatbot ? 1 : 0
  name        = "edgar-chatbot"
  description = "Streamlit UI for the EDGAR chatbot"
  vpc_id      = local.chatbot_vpc_id
  tags        = var.tags
}

# Repo 5's API and UI. Same allow-list as the chatbot: this is a demo host, and
# a read-only service over public SEC data still has no reason to face the whole
# internet.
resource "aws_vpc_security_group_ingress_rule" "serving_ui" {
  for_each = var.deploy_chatbot && var.chatbot_domain == "" ? toset(var.chatbot_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.chatbot[0].id
  description       = "EDGAR serving API and UI"
  cidr_ipv4         = each.value
  from_port         = 8055
  to_port           = 8055
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "chatbot_ui" {
  for_each = var.deploy_chatbot && var.chatbot_domain == "" ? toset(var.chatbot_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.chatbot[0].id
  description       = "Streamlit UI (plain HTTP, no domain configured)"
  cidr_ipv4         = each.value
  from_port         = 8501
  to_port           = 8501
  ip_protocol       = "tcp"
}

# 80 and 443 exist only when a domain is configured. 80 is not decorative:
# Caddy needs it reachable for the ACME HTTP-01 challenge, and afterwards it
# serves the redirect to HTTPS.
resource "aws_vpc_security_group_ingress_rule" "chatbot_https" {
  for_each = var.deploy_chatbot && var.chatbot_domain != "" ? toset(["80", "443"]) : toset([])

  security_group_id = aws_security_group.chatbot[0].id
  description       = "HTTPS (and ACME challenge on 80)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  ip_protocol       = "tcp"
}

# No SSH rule on purpose. Session Manager is not enabled either, so the host is
# reachable only on the one application port; rebuild rather than log in.
resource "aws_vpc_security_group_egress_rule" "chatbot_out" {
  count = var.deploy_chatbot ? 1 : 0

  security_group_id = aws_security_group.chatbot[0].id
  description       = "Bedrock, S3, SSM, package installs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- the host --------------------------------------------------------------
resource "aws_instance" "chatbot" {
  count = var.deploy_chatbot ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023_arm64[0].value
  instance_type          = var.chatbot_instance_type
  iam_instance_profile   = aws_iam_instance_profile.chatbot[0].name
  vpc_security_group_ids = [aws_security_group.chatbot[0].id]

  metadata_options {
    http_tokens   = "required" # IMDSv2 only: v1 is trivially SSRF-able
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    repo_url       = var.chatbot_repo_url
    serving_prefix = "s3://${var.serving_bucket}/v1"
    region         = data.aws_region.current.name
    model_main     = var.chat_model_main
    model_cheap    = var.chat_model_cheap
    token_budget   = var.chat_token_budget_day
    domain         = var.chatbot_domain
    # Behind Caddy, Streamlit binds loopback so 8501 is not separately
    # reachable; without a domain it must bind all interfaces to be usable.
    streamlit_bind = var.chatbot_domain != "" ? "127.0.0.1" : "0.0.0.0"

    # Repo 5 is co-hosted here. Same reasoning as streamlit_bind: loopback when
    # Caddy fronts it, all interfaces when it must be reachable directly.
    serving_repo_url = var.serving_repo_url
    serving_bucket   = var.serving_bucket
    contracts_repo   = var.contracts_repo
    serving_bind     = var.chatbot_domain != "" ? "127.0.0.1" : "0.0.0.0"
  })

  tags = merge(var.tags, { Name = "edgar-chatbot" })
}

# --- stable address --------------------------------------------------------
# An Elastic IP costs NOTHING extra here. Since Feb 2024 every public IPv4 is
# billed at $0.005/hr whether it is auto-assigned or elastic, and the instance
# already carries an auto-assigned one -- verified against the pricing API:
# both USE2-PublicIPv4:InUseAddress and :IdleAddress are $0.005/hr.
#
# What it buys is a link that survives a stop/start. Without it the address is
# reallocated on every restart, which silently breaks a URL already posted
# somewhere public.
#
# The one trap: an EIP left allocated after the instance is gone keeps billing
# as :IdleAddress. Destroying with `deploy_chatbot = false` releases it.
resource "aws_eip" "chatbot" {
  count    = var.deploy_chatbot ? 1 : 0
  instance = aws_instance.chatbot[0].id
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "edgar-chatbot" })
}
