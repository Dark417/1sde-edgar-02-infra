resource "aws_scheduler_schedule" "daily" {
  name        = "${var.name_prefix}-ingest-daily"
  description = "Daily EDGAR ingest. Created DISABLED; enabled by hand after repo 4 runs."

  state = var.schedule_enabled ? "ENABLED" : "DISABLED"

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "UTC"

  # OFF, not a window. A flexible window would let the run drift across the UTC
  # midnight boundary, which would change the logical date the job derives from
  # its start time — and the logical date is what every batch id and landing path
  # is built from.
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = var.cluster_arn
    role_arn = var.scheduler_role_arn

    ecs_parameters {
      task_definition_arn = var.task_definition_arn
      launch_type         = "FARGATE"
      task_count          = 1

      network_configuration {
        subnets          = var.subnet_ids
        security_groups  = var.security_group_ids
        assign_public_ip = true
      }
    }

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}
