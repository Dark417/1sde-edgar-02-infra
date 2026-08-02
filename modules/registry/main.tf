resource "aws_ecr_repository" "ingest" {
  name = "${var.name_prefix}-ingest"

  # IMMUTABLE is deliberate. The task definition pins by digest, and immutable
  # tags mean a tag can never be re-pointed at different bytes behind that pin.
  # The cost is that repo 3 must push uniquely-tagged images (git sha), never a
  # rolling ":latest" — which is the behaviour we want anyway.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# The retention count lives in a variable, and the resource name deliberately
# does NOT encode it.
#
# An ECR repository has exactly ONE lifecycle policy, so the Terraform resource
# name and the AWS object are not one-to-one. Renaming the resource — which is
# what happens if the name carries the count and the count changes — makes
# Terraform plan a create of the new address and a destroy of the old one
# against that single shared object. It applied "1 added, 1 destroyed" cleanly
# and then left the repository with NO policy at all, because the destroy ran
# after the create and deleted what had just been made. State claimed the policy
# existed; `aws ecr get-lifecycle-policy` returned LifecyclePolicyNotFound.
#
# With a stable resource name, changing the count is an in-place update and the
# object is never destroyed. The `moved` block below carries the two historical
# names into this one so existing state migrates instead of churning again.
resource "aws_ecr_lifecycle_policy" "expire_old_images" {
  repository = aws_ecr_repository.ingest.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last ${var.retained_image_count} images; expire older ones."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.retained_image_count
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}

moved {
  from = aws_ecr_lifecycle_policy.keep_last_3
  to   = aws_ecr_lifecycle_policy.expire_old_images
}
