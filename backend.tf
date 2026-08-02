# Terraform state backend.
#
# The bucket name is NOT hardcoded: it embeds the AWS account id and is supplied
# at init time (`terraform init -backend-config="bucket=$TF_BUCKET"`), because the
# bucket and lock table are created by hand before Terraform can run at all.
# See docs/BOOTSTRAP.md for why these two resources are the only ones in the
# project not under Terraform management.
terraform {
  backend "s3" {
    key    = "edgar-lakehouse/infra/terraform.tfstate"
    region = "us-east-2"

    # S3-native locking via conditional writes, not a DynamoDB table.
    #
    # `dynamodb_table` is deprecated: Terraform 1.10 added `use_lockfile`, which
    # takes the lock with a conditional PutObject of a .tflock object beside the
    # state file, and 1.11 marked the DynamoDB attribute for removal. Using it
    # deletes a whole resource from the bootstrap — the lock table was the second
    # of the four things Terraform could not create for itself, and now there are
    # three.
    #
    # Requires Terraform >= 1.10 everywhere, including CI.
    use_lockfile = true
    encrypt      = true
  }
}
