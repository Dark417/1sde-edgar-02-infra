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

# Session Manager. Added after the host failed at startup with a message the UI
# truncated, and there was no way to read the traceback: no SSH rule, no session
# access, so the only diagnostic move left was to replace the instance and hope
# the next boot said more. "Rebuild rather than log in" is a fine rule for
# changing the host; it is not a substitute for being able to read its logs.
#
# This opens no port. The agent dials out to the SSM endpoints over the egress
# rule that already exists, so the inbound posture is unchanged -- access is
# gated by IAM on who may call StartSession, not by a listening service.
resource "aws_iam_role_policy_attachment" "chatbot_ssm" {
  count      = var.deploy_chatbot ? 1 : 0
  role       = aws_iam_role.chatbot[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
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
#
# Gated on chatbot_domain exactly like the 8501 rule, and for the same reason:
# Caddy now routes `/` to repo 5 and `/chat` to the chatbot, so with a domain
# set repo 5 is served over TLS on 443 and 8055 is loopback-only. Leaving this
# rule open would expose a plaintext second door to the same content.
#
# It was briefly ungated, correctly, during the window when Caddy proxied only
# 8501 -- gating it then would have bound repo 5 to loopback behind a proxy with
# no route to it. The rule and the Caddyfile have to move together.
resource "aws_vpc_security_group_ingress_rule" "serving_ui" {
  for_each = var.deploy_chatbot && var.chatbot_domain == "" ? toset(var.chatbot_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.chatbot[0].id
  description       = "EDGAR serving API and UI"
  cidr_ipv4         = each.value
  from_port         = 8055
  to_port           = 8055
  ip_protocol       = "tcp"
}

# Only in the no-domain case. Once a domain is set Streamlit binds 127.0.0.1 and
# 8501 answers nobody from outside, so keeping the rule would leave a port open
# to the whole internet that grants no access -- an inbound rule that reads as
# reachable but is not is worse than no rule, because the next reader trusts it.
# The two paths are mutually exclusive by construction.
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
    # Behind Caddy, both apps bind loopback so neither port is separately
    # reachable; without a domain each must bind all interfaces to be usable.
    streamlit_bind = var.chatbot_domain != "" ? "127.0.0.1" : "0.0.0.0"

    # Where the assistant is mounted. Must match the Caddy `handle /chat*`
    # route: Streamlit generates its own asset and websocket URLs from this, so
    # a mismatch between the two produces a page that loads and never connects.
    # Empty when there is no domain, i.e. Streamlit owns the whole port.
    streamlit_base_path = var.chatbot_domain != "" ? "chat" : ""

    serving_repo_url = var.serving_repo_url
    serving_bucket   = var.serving_bucket
    contracts_repo   = var.contracts_repo
    serving_bind     = var.chatbot_domain != "" ? "127.0.0.1" : "0.0.0.0"

    # The two cross-links, both empty unless a domain joins the services under
    # one origin. Without one they run on separate ports with no shared path,
    # and each app renders no link rather than a broken one.
    chat_url = var.chatbot_domain != "" ? "/chat/" : ""
    site_url = var.chatbot_domain != "" ? "https://${var.chatbot_domain}/" : ""
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
