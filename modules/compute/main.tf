data "aws_region" "current" {}

# The default VPC is used deliberately. A purpose-built VPC with NAT gateways
# would cost roughly $32/month in NAT charges alone — more than the rest of this
# project combined — to isolate a batch job that talks only to public endpoints
# (sec.gov, S3, Secrets Manager, Databricks). The task runs in a public subnet
# with a public IP and no inbound rules.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# Fargate only. No EC2 capacity provider: there is no steady-state workload here
# to amortise an instance against, and a always-on instance would be the single
# largest line on the bill.
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_security_group" "task" {
  name        = "${var.name_prefix}-ingest-task"
  description = "Egress-only security group for the ingest task."
  vpc_id      = data.aws_vpc.default.id

  # No ingress rules at all. Nothing connects to this task; it is a batch job
  # that makes outbound calls and exits.
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.task.id
  description       = "HTTPS to sec.gov, S3, Secrets Manager, SSM and Databricks."

  # tfsec:ignore:aws-ec2-no-public-egress-sgr
  # The destinations are public API endpoints across several AWS-owned and
  # SEC-owned ranges that do not have stable published CIDRs. Restricting egress
  # would mean VPC endpoints for the AWS services plus an allowlist for sec.gov
  # that breaks whenever their CDN moves. Inbound is what matters here, and it is
  # empty.
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

locals {
  # Digest beats tag. The tag path exists only for the first apply, when the ECR
  # repository is still empty and no digest can exist yet.
  image = var.image_digest != "" ? "${var.repository_url}@${var.image_digest}" : "${var.repository_url}:${var.image_tag}"

  # Sorted so the rendered JSON is stable. An unsorted map here would reorder
  # between plans and show a permanent diff, which rule 11 forbids.
  environment = [
    for k in sort(keys(var.ingest_env)) : {
      name  = k
      value = var.ingest_env[k]
    }
  ]

  secrets = [
    for k in sort(keys(var.secret_env)) : {
      name      = k
      valueFrom = var.secret_env[k]
    }
  ]
}

resource "aws_ecs_task_definition" "ingest" {
  family                   = var.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  task_role_arn            = var.task_role_arn
  execution_role_arn       = var.execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "ingest"
      image     = local.image
      essential = true

      # Non-secret config only. Anything sensitive goes through `secrets` below
      # so the value is resolved by the ECS agent at start time and never lands
      # in the task definition or in state.
      environment = local.environment
      secrets     = local.secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ingest.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ingest"
        }
      }
    },
  ])
}
