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

# Three, not ten. The ECR free tier is 500 MB-month on private repositories;
# the ingest image is budgeted under 250 MB, so ten retained images can cross it
# even with layer sharing and start billing against a $10/month alarm. Three
# covers the only real need -- roll back to the previous digest, with one spare.
resource "aws_ecr_lifecycle_policy" "keep_last_3" {
  repository = aws_ecr_repository.ingest.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 3 images; expire older ones."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 3
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}
