variable "name_prefix" {
  description = "Prefix for resource names, e.g. \"edgar-lakehouse\"."
  type        = string
}

variable "retained_image_count" {
  description = <<-EOT
    How many images the lifecycle policy keeps. A variable rather than part of
    the resource name: the ECR free tier is 500 MB-month on private repositories
    and the ingest image is budgeted under 250 MB, so this number is a cost knob
    that will get tuned — and tuning it must be an in-place update, never a
    rename. See the note in main.tf for what a rename did the first time.

    Three covers the only real need: roll back to the previous digest, plus one
    spare.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.retained_image_count >= 2
    error_message = "Keep at least 2 images, or there is nothing to roll back to."
  }
}
