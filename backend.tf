# Terraform state backend.
#
# The bucket name is NOT hardcoded: it embeds the AWS account id and is supplied
# at init time (`terraform init -backend-config="bucket=$TF_BUCKET"`), because the
# bucket and lock table are created by hand before Terraform can run at all.
# See docs/BOOTSTRAP.md for why these two resources are the only ones in the
# project not under Terraform management.
terraform {
  backend "s3" {
    key            = "edgar-lakehouse/infra/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "edgar-lakehouse-tflock"
    encrypt        = true
  }
}
