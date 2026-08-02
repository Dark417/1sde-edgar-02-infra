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
  description = <<-EOT
    Account-level principal receiving grants, normally a user's email. Empty
    disables the grant resources entirely. Workspace-local groups such as `users`
    do NOT resolve in Unity Catalog.
  EOT
  type        = string
  default     = ""
}

