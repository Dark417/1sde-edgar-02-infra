# Without this, Terraform infers the provider namespace from the resource prefix
# and looks for `hashicorp/databricks`, which does not exist. Every module that
# uses a non-HashiCorp provider has to name its source.
terraform {
  required_version = ">= 1.9"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
  }
}
