# ---------------------------------------------------------------------------
# Repo 6 (1sde-edgar-06-chatbot) footprint: configuration only.
#
# Deliberately NO compute here yet. An always-on Fargate service plus an ALB
# is $30+/month against this project's $10 budget alarm, and the chatbot is
# local-first by design (its docs/20-agent-system.md §8). When a cloud deploy
# is wanted, the ECS service/task/SG land here behind var.deploy_chatbot.
# ---------------------------------------------------------------------------

locals {
  chat_parameters = {
    # Consumed by: repo 6 guard (kill switch, cached 30 s per message).
    "/edgar-lakehouse/chat/enabled" = var.chat_enabled

    # Consumed by: repo 6 config. Empty string means "probe the candidate
    # list at startup" (Anthropic models are gated behind the Bedrock
    # use-case form; Nova works without it). Set to a concrete model id to
    # pin, e.g. after the form is approved.
    "/edgar-lakehouse/chat/model/main"  = var.chat_model_main
    "/edgar-lakehouse/chat/model/cheap" = var.chat_model_cheap

    # Consumed by: repo 6 guard (global daily token ceiling).
    "/edgar-lakehouse/chat/token_budget_day" = tostring(var.chat_token_budget_day)
  }
}

resource "aws_ssm_parameter" "chat" {
  for_each = local.chat_parameters

  name  = each.key
  type  = "String"
  value = each.value

  tags = var.tags
}

# The optional Anthropic direct-API key. Terraform creates the CONTAINER with a
# placeholder value only; the real value is set by hand (aws secretsmanager
# put-secret-value) so plaintext never enters state — same rule 5 discipline as
# the Databricks PAT. Bedrock needs no key at all; this exists for the direct
# Anthropic API fallback and stays a placeholder until someone needs that path.
resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name        = "/edgar-lakehouse/chat/anthropic_api_key"
  description = "Optional Anthropic API key for repo 6 direct-API fallback. Placeholder until set by hand; see repo 6 docs/SETUP-CREDENTIALS.md."

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "anthropic_api_key_placeholder" {
  secret_id     = aws_secretsmanager_secret.anthropic_api_key.id
  secret_string = "PLACEHOLDER-set-me"

  # The human overwrites this by hand; Terraform must never revert it and the
  # real value must never enter state. Ignoring changes is what makes the
  # placeholder pattern compatible with rule 5.
  lifecycle {
    ignore_changes = [secret_string]
  }
}
