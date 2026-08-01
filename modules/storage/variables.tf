variable "raw_bucket" {
  description = "Name of the system-of-record landing bucket."
  type        = string
}

variable "serving_bucket" {
  description = "Name of the Parquet export bucket."
  type        = string
}

variable "ia_transition_days" {
  description = "Days before objects transition to STANDARD_IA."
  type        = number
  default     = 90
}

variable "terraform_role_arn" {
  description = <<-EOT
    The only principal permitted to delete from the raw bucket. Everything else
    is denied by bucket policy, including the ingest task.
  EOT
  type        = string
}

variable "serving_reader_role_arns" {
  description = "Roles granted read access to the serving bucket (repo 5's API)."
  type        = list(string)
  default     = []
}
