output "state" {
  description = "ENABLED or DISABLED. §11 requires this to read DISABLED after the first apply."
  value       = aws_scheduler_schedule.daily.state
}

output "schedule_arn" {
  description = "Schedule ARN."
  value       = aws_scheduler_schedule.daily.arn
}

output "schedule_name" {
  description = "Schedule name."
  value       = aws_scheduler_schedule.daily.name
}
