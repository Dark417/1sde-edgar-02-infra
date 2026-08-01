variable "catalog" {
  description = "Catalog name, mirrored from contracts (`names.CATALOG`)."
  type        = string
}

variable "schemas" {
  description = "Schema key -> name, mirrored from contracts."
  type        = map(string)
}

variable "volume_schema" {
  description = "Schema holding the landing volume."
  type        = string
}

variable "volume_name" {
  description = "Landing volume name, derived from `names.VOLUME_LANDING`."
  type        = string
}

variable "workspace_principal" {
  description = "Principal receiving grants (group or account email)."
  type        = string
}

variable "wheel_dir" {
  description = "Volume directory holding the repo-4 wheel."
  type        = string
}

variable "wheel_version" {
  description = "Exact repo-4 wheel version each task installs. Never \"latest\"."
  type        = string
}

variable "job_name" {
  description = "Name of the daily medallion job."
  type        = string
}

variable "job_schedule_enabled" {
  description = <<-EOT
    Mirrors var.schedule_enabled. The job is created PAUSED for the same reason
    the EventBridge schedule is created DISABLED.
  EOT
  type        = bool
  default     = false
}

variable "job_schedule_expression" {
  description = <<-EOT
    07:00 UTC — one hour after the 06:00 ingest run, so the landing zone is
    settled before Auto Loader reads it. Quartz syntax (seconds first).
  EOT
  type        = string
  default     = "0 0 7 * * ?"
}
